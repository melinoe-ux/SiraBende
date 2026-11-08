// sbqctl — test/control helper for SiraBende.
//   sbqctl "next 123456789"   writes a command file and notifies the Music app
//   sbqctl --launch           launches the Music app (SpringBoardServices)
//   sbqctl --play/--pause/--next, --playpid <pid>   transport controls
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <notify.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static int launch_music(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    int (*launch)(CFStringRef, Boolean) = (int (*)(CFStringRef, Boolean))dlsym(h, "SBSLaunchApplicationWithIdentifier");
    if (!launch) { fprintf(stderr, "no SBSLaunchApplicationWithIdentifier\n"); return 1; }
    int r = launch(CFSTR("com.apple.mobileipod"), false);
    printf("launch result %d\n", r);
    return r == 0 ? 0 : 1;
}

// Sends play/pause/next to MPMusicPlayerController.iPodMusicPlayer; if the Music app is
// not running, iOS launches it in the background.
#include <objc/runtime.h>
#include <objc/message.h>
static int music_cmd(const char *sel) {
    void *h = dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_LAZY);
    if (!h) { fprintf(stderr, "dlopen MediaPlayer failed\n"); return 1; }
    id pool = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSAutoreleasePool"), sel_registerName("new"));
    id pc = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("MPMusicPlayerController"), sel_registerName("iPodMusicPlayer"));
    if (!pc) { fprintf(stderr, "no player\n"); return 1; }
    ((void (*)(id, SEL))objc_msgSend)(pc, sel_registerName(sel));
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.5, false);
    long state = ((long (*)(id, SEL))objc_msgSend)(pc, sel_registerName("playbackState"));
    printf("%s -> playbackState %ld\n", sel, state);
    ((void (*)(id, SEL))objc_msgSend)(pool, sel_registerName("drain"));
    return 0;
}

// --playpid <persistentID>: plays exactly that song and reports whether time advances
static int play_pid(const char *pidstr) {
    void *h = dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_LAZY);
    if (!h) return 1;
    id pool = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSAutoreleasePool"), sel_registerName("new"));
    unsigned long long pid = strtoull(pidstr, NULL, 10);
    id num = ((id (*)(id, SEL, unsigned long long))objc_msgSend)((id)objc_getClass("NSNumber"), sel_registerName("numberWithUnsignedLongLong:"), pid);
    id key = *(id *)dlsym(h, "MPMediaItemPropertyPersistentID");
    id pred = ((id (*)(id, SEL, id, id))objc_msgSend)((id)objc_getClass("MPMediaPropertyPredicate"), sel_registerName("predicateWithValue:forProperty:"), num, key);
    id q = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("MPMediaQuery"), sel_registerName("songsQuery"));
    ((void (*)(id, SEL, id))objc_msgSend)(q, sel_registerName("addFilterPredicate:"), pred);
    id items = ((id (*)(id, SEL))objc_msgSend)(q, sel_registerName("items"));
    unsigned long n = ((unsigned long (*)(id, SEL))objc_msgSend)(items, sel_registerName("count"));
    printf("matches: %lu\n", n);
    if (!n) return 1;
    id pc = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("MPMusicPlayerController"), sel_registerName("iPodMusicPlayer"));
    ((void (*)(id, SEL, id))objc_msgSend)(pc, sel_registerName("setQueueWithQuery:"), q);
    ((void (*)(id, SEL))objc_msgSend)(pc, sel_registerName("play"));
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false);
    double t1 = ((double (*)(id, SEL))objc_msgSend)(pc, sel_registerName("currentPlaybackTime"));
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3.0, false);
    double t2 = ((double (*)(id, SEL))objc_msgSend)(pc, sel_registerName("currentPlaybackTime"));
    id now = ((id (*)(id, SEL))objc_msgSend)(pc, sel_registerName("nowPlayingItem"));
    id title = now ? ((id (*)(id, SEL, id))objc_msgSend)(now, sel_registerName("valueForProperty:"), *(id *)dlsym(h, "MPMediaItemPropertyTitle")) : nil;
    const char *ct = title ? ((const char *(*)(id, SEL))objc_msgSend)(title, sel_registerName("UTF8String")) : "(none)";
    long state = ((long (*)(id, SEL))objc_msgSend)(pc, sel_registerName("playbackState"));
    printf("now playing: %s  state=%ld  time %.1f -> %.1f (%s)\n", ct, state, t1, t2, t2 > t1 + 1 ? "PLAYING OK" : "NOT ADVANCING");
    ((void (*)(id, SEL))objc_msgSend)(pc, sel_registerName("pause"));
    ((void (*)(id, SEL))objc_msgSend)(pool, sel_registerName("drain"));
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 2 && argv[1][0] == '-' && argv[1][1] == '-' && argv[1][2] == 'p' && argv[1][3] == 'l' && argv[1][6] == 'p') return play_pid(argv[2]);
    if (argc > 1 && argv[1][0] == '-' && argv[1][1] == '-' && argv[1][2] == 'l') return launch_music();
    if (argc > 1 && argv[1][0] == '-' && argv[1][1] == '-' && argv[1][2] == 'p' && argv[1][3] == 'l') return music_cmd("play");
    if (argc > 1 && argv[1][0] == '-' && argv[1][1] == '-' && argv[1][2] == 'p' && argv[1][3] == 'a') return music_cmd("pause");
    if (argc > 1 && argv[1][0] == '-' && argv[1][1] == '-' && argv[1][2] == 'n') return music_cmd("skipToNextItem");
    if (argc > 1) {
        mkdir("/var/mobile/Library/Caches/SiraBende", 0755);
        FILE *f = fopen("/var/mobile/Library/Caches/SiraBende/cmd.txt", "w");
        if (!f) { perror("cmd.txt"); return 1; }
        for (int i = 1; i < argc; i++) fprintf(f, "%s%s", i > 1 ? " " : "", argv[i]);
        fclose(f);
    }
    return notify_post("com.sirabende.cmd") == 0 ? 0 : 1;
}

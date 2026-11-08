// SiraBende — Apple Music style swipe actions for the iOS 6 Music app:
// "Play Next" and "Add to Queue".
//
// Swipe a song/album row to the right:
//   short (>= 22% of width) -> Play Next
//   long  (>= 50% of width) -> Add to Queue
//
// Queue engine: songs are appended to IUMediaQueryQueueFeeder's prefixMediaItems and
// mapped to positions right after the current song through a virtual index map, so the
// Music app's own playback machinery creates and plays them.

#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <notify.h>

// ---------------------------------------------------------------- private API

@interface MPAVPlaylistManager : NSObject
- (int)currentIndex;
@end

@interface MPAVController : NSObject
- (id)feeder;
- (MPAVPlaylistManager *)_avPlaylistManager;
- (BOOL)isPlaying;
- (unsigned)state;
- (unsigned)numberOfItems;
@end

@interface IUiPodAVController : MPAVController
+ (id)sharedInstance;
@end

@interface MPQueueFeeder : NSObject
- (unsigned)itemCount;
- (MPAVController *)AVController;
- (void)contentInvalidatedWithCurrentItemMovedToIndex:(unsigned)idx;
- (void)contentInvalidated;
@end

@interface IUMediaQueryQueueFeeder : MPQueueFeeder
- (NSArray *)prefixMediaItems;
- (void)setPrefixMediaItems:(NSArray *)items;
- (MPMediaItem *)mediaItemAtIndex:(unsigned)idx;
- (unsigned)indexOfMediaItem:(MPMediaItem *)item;
- (MPMediaQuery *)query;
@end

@interface IUTableCellConfiguration : NSObject
@end

@interface IUMediaEntityCellConfiguration : IUTableCellConfiguration
- (MPMediaEntity *)entity;
@end

@interface IUMediaTableCell : UITableViewCell
- (IUTableCellConfiguration *)configuration;
@end

@interface IUTableViewController : UIViewController
@end

// ---------------------------------------------------------------- logging

static NSString *const kSBDir = @"/var/mobile/Library/Caches/SiraBende";

static void SBLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *path = [kSBDir stringByAppendingPathComponent:@"log.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kSBDir])
        [fm createDirectoryAtPath:kSBDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static NSString *SBTitle(MPMediaItem *item) {
    if (!item) return @"(nil)";
    NSString *t = [item valueForProperty:MPMediaItemPropertyTitle];
    NSString *a = [item valueForProperty:MPMediaItemPropertyArtist];
    return [NSString stringWithFormat:@"%@ — %@", t ?: @"?", a ?: @"?"];
}

// ---------------------------------------------------------------- queue state
//
// Native feeder order: base indices b = 0..N-1, raw index = b, except that the
// feeder's prefix array is [nativePrefix (K items)] + [our items (m items)], so
// raw indices of native items >= K are shifted by m.
// Our items live at raw K..K+m-1 and are placed at chosen virtual positions.

@interface SBQueueState : NSObject
@property (nonatomic, retain) NSArray *nativePrefix;   // K items
@property (nonatomic, retain) NSMutableArray *ours;    // m MPMediaItems (raw K+i)
@property (nonatomic, retain) NSMutableArray *virtPos; // NSNumber virtual index per ours[i]
@end
@implementation SBQueueState
- (id)init {
    if ((self = [super init])) {
        _ours = [NSMutableArray new];
        _virtPos = [NSMutableArray new];
    }
    return self;
}
@end

static char kSBStateKey;
static BOOL gSBSettingPrefix = NO;

static SBQueueState *SBState(id feeder, BOOL create) {
    SBQueueState *s = objc_getAssociatedObject(feeder, &kSBStateKey);
    if (!s && create) {
        s = [SBQueueState new];
        s.nativePrefix = [(IUMediaQueryQueueFeeder *)feeder prefixMediaItems] ?: @[];
        objc_setAssociatedObject(feeder, &kSBStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

static unsigned SBRawForVirtual(SBQueueState *s, unsigned v) {
    if (!s || s.ours.count == 0) return v;
    unsigned before = 0;
    for (NSUInteger i = 0; i < s.virtPos.count; i++) {
        unsigned p = [s.virtPos[i] unsignedIntValue];
        if (p == v) return (unsigned)(s.nativePrefix.count + i);
        if (p < v) before++;
    }
    unsigned b = v - before;
    unsigned K = (unsigned)s.nativePrefix.count;
    return b < K ? b : b + (unsigned)s.ours.count;
}

static unsigned SBVirtualForRaw(SBQueueState *s, unsigned raw) {
    if (!s || s.ours.count == 0 || raw == NSNotFound) return raw;
    unsigned K = (unsigned)s.nativePrefix.count;
    unsigned m = (unsigned)s.ours.count;
    if (raw >= K && raw < K + m) return [s.virtPos[raw - K] unsignedIntValue];
    unsigned b = raw < K ? raw : raw - m;
    NSArray *sorted = [s.virtPos sortedArrayUsingSelector:@selector(compare:)];
    unsigned v = b;
    for (NSNumber *n in sorted)
        if ([n unsignedIntValue] <= v) v++;
    return v;
}

static void SBApplyPrefix(IUMediaQueryQueueFeeder *feeder, SBQueueState *s) {
    gSBSettingPrefix = YES;
    [feeder setPrefixMediaItems:[s.nativePrefix arrayByAddingObjectsFromArray:s.ours]];
    gSBSettingPrefix = NO;
}

static void SBClear(IUMediaQueryQueueFeeder *feeder, NSString *why) {
    SBQueueState *s = SBState(feeder, NO);
    if (!s) return;
    SBLog(@"clear (%@), had %u queued", why, (unsigned)s.ours.count);
    objc_setAssociatedObject(feeder, &kSBStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gSBSettingPrefix = YES;
    [feeder setPrefixMediaItems:s.nativePrefix.count ? s.nativePrefix : nil];
    gSBSettingPrefix = NO;
}

static IUiPodAVController *SBController(void) {
    Class c = objc_getClass("IUiPodAVController");
    return c ? [c sharedInstance] : nil;
}

static IUMediaQueryQueueFeeder *SBActiveFeeder(void) {
    id feeder = [SBController() feeder];
    Class fc = objc_getClass("IUMediaQueryQueueFeeder");
    if (feeder && fc && [feeder isKindOfClass:fc]) return feeder;
    return nil;
}

static int SBCurrentIndex(void) {
    MPAVPlaylistManager *pm = [SBController() _avPlaylistManager];
    return pm ? [pm currentIndex] : -1;
}

typedef NS_ENUM(int, SBMode) { SBModePlayNext = 1, SBModeAddToQueue = 2 };

static NSArray *SBItemsForEntity(MPMediaEntity *entity) {
    if ([entity isKindOfClass:[MPMediaItem class]]) return @[ entity ];
    if ([entity isKindOfClass:[MPMediaItemCollection class]]) return [(MPMediaItemCollection *)entity items];
    return nil;
}

// returns number of items inserted
static unsigned SBEnqueue(NSArray *items, SBMode mode) {
    if (items.count == 0) return 0;
    IUMediaQueryQueueFeeder *feeder = SBActiveFeeder();
    int cur = SBCurrentIndex();
    if (!feeder || cur < 0 || [feeder itemCount] == 0) {
        // nothing loaded: just play these items. The iPod music player server lives on
        // this app's main thread, so talk to it from a background queue (else deadlock).
        MPMediaItemCollection *col = [MPMediaItemCollection collectionWithItems:items];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            MPMusicPlayerController *pc = [MPMusicPlayerController iPodMusicPlayer];
            [pc setQueueWithItemCollection:col];
            [pc play];
        });
        SBLog(@"no active queue, started playing %u item(s)", (unsigned)items.count);
        return (unsigned)items.count;
    }

    SBQueueState *s = SBState(feeder, YES);
    unsigned before = [feeder itemCount];

    // position: Play Next -> right after current; Add to Queue -> after the run of
    // our queued items that directly follows the current one.
    unsigned pos = (unsigned)cur + 1;
    if (mode == SBModeAddToQueue) {
        NSMutableSet *taken = [NSMutableSet set];
        for (NSNumber *n in s.virtPos) [taken addObject:n];
        while ([taken containsObject:@(pos)]) pos++;
    }

    for (MPMediaItem *item in items) {
        for (NSUInteger i = 0; i < s.virtPos.count; i++) {
            unsigned p = [s.virtPos[i] unsignedIntValue];
            if (p >= pos) s.virtPos[i] = @(p + 1);
        }
        [s.ours addObject:item];
        [s.virtPos addObject:@(pos)];
        pos++;
    }
    SBApplyPrefix(feeder, s);

    unsigned after = [feeder itemCount];
    SBLog(@"enqueue mode=%d cur=%d items=%u count %u->%u (K=%u m=%u)", mode, cur,
          (unsigned)items.count, before, after, (unsigned)s.nativePrefix.count, (unsigned)s.ours.count);
    [feeder contentInvalidatedWithCurrentItemMovedToIndex:(unsigned)cur];
    return (unsigned)items.count;
}

static void SBDump(void) {
    IUMediaQueryQueueFeeder *feeder = SBActiveFeeder();
    int cur = SBCurrentIndex();
    SBQueueState *s = feeder ? SBState(feeder, NO) : nil;
    SBLog(@"dump: feeder=%@ cur=%d count=%u prefix=%u ours=%u", [feeder class], cur,
          feeder ? [feeder itemCount] : 0, (unsigned)[[feeder prefixMediaItems] count], (unsigned)s.ours.count);
    id avItem = [(id)SBController() performSelector:@selector(currentItem)];
    MPMediaItem *playing = [avItem respondsToSelector:@selector(mediaItem)] ? [avItem performSelector:@selector(mediaItem)] : nil;
    SBLog(@"  now playing (AVController): %@", SBTitle(playing));
    if (!feeder) return;
    unsigned n = [feeder itemCount];
    int from = MAX(0, cur - 2);
    for (unsigned i = (unsigned)from; i < n && i < (unsigned)from + 12; i++)
        SBLog(@"  %@%u: %@", (int)i == cur ? @">" : @" ", i, SBTitle([feeder mediaItemAtIndex:i]));
}

// ---------------------------------------------------------------- feeder hooks
//
// Only the outermost call is translated from virtual to raw indices: the feeder's own
// implementations call each other (e.g. copyRawItemAtIndex: -> mediaItemAtIndex:) with
// raw indices, and those nested calls must pass through untouched.

static int gSBDepth = 0; // feeder is only used on the main thread

#define SB_MAP_IN(idx) (gSBDepth == 0 ? SBRawForVirtual(SBState(self, NO), (idx)) : (idx))
#define SB_ENTER gSBDepth++
#define SB_LEAVE gSBDepth--

%hook IUMediaQueryQueueFeeder

- (id)copyRawItemAtIndex:(unsigned)idx {
    unsigned r = SB_MAP_IN(idx); SB_ENTER; id x = %orig(r); SB_LEAVE; return x;
}
- (id)playbackInfoAtIndex:(unsigned)idx {
    unsigned r = SB_MAP_IN(idx); SB_ENTER; id x = %orig(r); SB_LEAVE; return x;
}
- (id)pathAtIndex:(unsigned)idx {
    unsigned r = SB_MAP_IN(idx); SB_ENTER; id x = %orig(r); SB_LEAVE; return x;
}
- (unsigned)itemTypeForIndex:(unsigned)idx {
    unsigned r = SB_MAP_IN(idx); SB_ENTER; unsigned x = %orig(r); SB_LEAVE; return x;
}
- (MPMediaItem *)mediaItemAtIndex:(unsigned)idx {
    unsigned r = SB_MAP_IN(idx); SB_ENTER; MPMediaItem *x = %orig(r); SB_LEAVE; return x;
}

- (unsigned)indexOfMediaItem:(MPMediaItem *)item {
    BOOL outer = gSBDepth == 0;
    SB_ENTER; unsigned raw = %orig; SB_LEAVE;
    return outer ? SBVirtualForRaw(SBState(self, NO), raw) : raw;
}

- (void)setSubsequenceFocused:(BOOL)focused currentItemIndex:(unsigned)idx {
    unsigned r = SB_MAP_IN(idx); SB_ENTER; %orig(focused, r); SB_LEAVE;
}

- (void)setPrefixMediaItems:(NSArray *)items {
    if (!gSBSettingPrefix && SBState(self, NO)) {
        objc_setAssociatedObject(self, &kSBStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SBLog(@"app changed prefix -> queue cleared");
    }
    %orig;
}

- (void)setQuery:(MPMediaQuery *)q {
    SBClear(self, @"setQuery");
    %orig;
}

- (void)shuffleItemsWithAnchor:(unsigned *)anchor {
    SBClear(self, @"shuffle");
    %orig;
}

- (BOOL)reloadWithDataSource:(id)ds keepPlayingCurrentItemIfPossible:(BOOL)keep {
    SBClear(self, @"reload");
    return %orig;
}

%end

// ---------------------------------------------------------------- toast

static void SBToast(NSString *text) {
    UIWindow *win = [[UIApplication sharedApplication] keyWindow];
    if (!win) return;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text;
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    l.font = [UIFont boldSystemFontOfSize:15];
    l.textAlignment = NSTextAlignmentCenter;
    l.layer.cornerRadius = 10;
    l.layer.masksToBounds = YES;
    CGSize sz = [text sizeWithFont:l.font];
    CGFloat w = MIN(sz.width + 32, win.bounds.size.width - 40);
    l.frame = CGRectMake((win.bounds.size.width - w) / 2, win.bounds.size.height - 120, w, 36);
    l.alpha = 0;
    [win addSubview:l];
    [UIView animateWithDuration:0.18 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:1.2 options:0 animations:^{ l.alpha = 0; }
                         completion:^(BOOL f2) { [l removeFromSuperview]; }];
    }];
}

// ---------------------------------------------------------------- swipe UI

static const CGFloat kSBNextFrac = 0.22;
static const CGFloat kSBQueueFrac = 0.50;

// The Music app draws its rows in its own content view, so instead of moving the
// cell's subviews we take a snapshot of the row, lay a coloured action bar over the
// row, and slide the snapshot on top of the bar (Apple Music style).

@interface SBSwipePan : UIPanGestureRecognizer
@property (nonatomic, retain) UIView *bar;        // coloured action bar
@property (nonatomic, retain) UILabel *label;     // action title on the bar
@property (nonatomic, retain) UIImageView *slider; // snapshot of the row
@property (nonatomic, assign) int armed;
@end
@implementation SBSwipePan
@end

@interface SBSwipeHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end

static MPMediaEntity *SBEntityForCell(UITableViewCell *cell) {
    if (![cell respondsToSelector:@selector(configuration)]) return nil;
    id conf = [(IUMediaTableCell *)cell configuration];
    if (![conf respondsToSelector:@selector(entity)]) return nil;
    return [(IUMediaEntityCellConfiguration *)conf entity];
}

static UIImage *SBSnapshot(UIView *v) {
    UIGraphicsBeginImageContextWithOptions(v.bounds.size, YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setFill];
    CGContextFillRect(ctx, v.bounds);
    [v.layer renderInContext:ctx];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

@implementation SBSwipeHandler

+ (instancetype)shared {
    static SBSwipeHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [SBSwipeHandler new]; });
    return h;
}

- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)g {
    UITableViewCell *cell = (UITableViewCell *)g.view;
    if (cell.editing) return NO;
    if (!SBItemsForEntity(SBEntityForCell(cell)).count) return NO;
    CGPoint v = [g velocityInView:cell];
    return v.x > 0 && fabsf(v.x) > fabsf(v.y) * 1.5f;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return NO;
}

- (void)setArmed:(int)armed on:(SBSwipePan *)g {
    if (g.armed == armed) return;
    g.armed = armed;
    UIColor *c = armed == SBModeAddToQueue ? [UIColor colorWithRed:0.46 green:0.31 blue:0.86 alpha:1]
               : armed == SBModePlayNext   ? [UIColor colorWithRed:0.98 green:0.53 blue:0.10 alpha:1]
                                           : [UIColor colorWithWhite:0.62 alpha:1];
    g.label.text = armed == SBModeAddToQueue ? @"Add to Queue" : @"Play Next";
    [UIView animateWithDuration:0.15 animations:^{ g.bar.backgroundColor = c; }];
}

- (void)begin:(SBSwipePan *)g cell:(UITableViewCell *)cell {
    CGFloat w = cell.bounds.size.width;
    CGFloat h = cell.bounds.size.height;
    {
        UIView *bar = [[UIView alloc] initWithFrame:cell.bounds];
        bar.clipsToBounds = YES;
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, w - 28, h)];
        lab.backgroundColor = [UIColor clearColor];
        lab.textColor = [UIColor whiteColor];
        lab.font = [UIFont boldSystemFontOfSize:17];
        lab.shadowColor = [UIColor colorWithWhite:0 alpha:0.25];
        lab.shadowOffset = CGSizeMake(0, 1);
        [bar addSubview:lab];

        UIImageView *slider = [[UIImageView alloc] initWithImage:SBSnapshot(cell)];
        slider.frame = cell.bounds;
        slider.layer.shadowColor = [UIColor blackColor].CGColor;
        slider.layer.shadowOpacity = 0.35f;
        slider.layer.shadowRadius = 4;
        slider.layer.shadowOffset = CGSizeMake(-2, 0);
        slider.layer.shadowPath = [UIBezierPath bezierPathWithRect:slider.bounds].CGPath;

        [cell addSubview:bar];
        [cell addSubview:slider];
        g.bar = bar;
        g.label = lab;
        g.slider = slider;
        g.armed = -1;
        [self setArmed:0 on:g];
    }
}

- (void)move:(SBSwipePan *)g cell:(UITableViewCell *)cell dx:(CGFloat)dx {
    CGFloat w = cell.bounds.size.width;
    CGRect f = g.slider.frame;
    f.origin.x = dx;
    g.slider.frame = f;
    int armed = dx >= w * kSBQueueFrac ? SBModeAddToQueue : dx >= w * kSBNextFrac ? SBModePlayNext : 0;
    [self setArmed:armed on:g];
}

- (void)pan:(SBSwipePan *)g {
    UITableViewCell *cell = (UITableViewCell *)g.view;
    CGFloat w = cell.bounds.size.width;
    CGFloat dx = MAX(0, MIN([g translationInView:cell].x, w * 0.85f));

    switch (g.state) {
    case UIGestureRecognizerStateBegan:
        [self begin:g cell:cell];
        break;
    case UIGestureRecognizerStateChanged:
        [self move:g cell:cell dx:dx];
        break;
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed: {
        int armed = g.state == UIGestureRecognizerStateEnded ? g.armed : 0;
        UIView *bar = g.bar;
        UIImageView *slider = g.slider;
        g.bar = nil;
        g.label = nil;
        g.slider = nil;
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            CGRect f = slider.frame;
            f.origin.x = 0;
            slider.frame = f;
        } completion:^(BOOL fin) {
            [slider removeFromSuperview];
            [bar removeFromSuperview];
        }];
        if (armed > 0) {
            NSArray *items = SBItemsForEntity(SBEntityForCell(cell));
            unsigned n = SBEnqueue(items, (SBMode)armed);
            if (n) {
                NSString *what = n == 1 ? ([items[0] valueForProperty:MPMediaItemPropertyTitle] ?: @"1 song")
                                        : [NSString stringWithFormat:@"%u songs", n];
                SBToast([NSString stringWithFormat:@"%@: %@",
                         armed == SBModePlayNext ? @"Playing Next" : @"Added to Queue", what]);
            }
        }
        break;
    }
    default:
        break;
    }
}

@end

static void SBAttach(UITableViewCell *cell) {
    for (UIGestureRecognizer *g in cell.gestureRecognizers)
        if ([g isKindOfClass:[SBSwipePan class]]) return;
    SBSwipePan *pan = [[SBSwipePan alloc] initWithTarget:[SBSwipeHandler shared] action:@selector(pan:)];
    pan.delegate = [SBSwipeHandler shared];
    [cell addGestureRecognizer:pan];
}

%hook IUTableViewController
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = %orig;
    Class mc = objc_getClass("IUMediaTableCell");
    if (cell && mc && [cell isKindOfClass:mc]) SBAttach(cell);
    return cell;
}
%end

// ---------------------------------------------------------------- remote test channel
// echo "next <persistentID>" > /var/mobile/Library/Caches/SiraBende/cmd.txt; sbqctl

static MPMediaItem *SBItemForPID(unsigned long long pid) {
    MPMediaQuery *q = [MPMediaQuery songsQuery];
    [q addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:@(pid)
                                                           forProperty:MPMediaItemPropertyPersistentID]];
    NSArray *items = q.items;
    return items.count ? items[0] : nil;
}

static void SBRunCommand(void) {
    NSString *path = [kSBDir stringByAppendingPathComponent:@"cmd.txt"];
    NSString *cmd = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    cmd = [cmd stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!cmd.length) return;
    SBLog(@"cmd: %@", cmd);
    NSArray *parts = [cmd componentsSeparatedByString:@" "];
    NSString *verb = parts[0];
    if ([verb isEqualToString:@"dump"]) {
        SBDump();
    } else if ([verb isEqualToString:@"songs"]) {
        NSArray *items = [MPMediaQuery songsQuery].items;
        for (NSUInteger i = 0; i < items.count && i < 400; i++) {
            MPMediaItem *it = items[i];
            SBLog(@"song %@ %@", [it valueForProperty:MPMediaItemPropertyPersistentID], SBTitle(it));
        }
    } else if (([verb isEqualToString:@"next"] || [verb isEqualToString:@"queue"]) && parts.count > 1) {
        MPMediaItem *it = SBItemForPID(strtoull([parts[1] UTF8String], NULL, 10));
        SBLog(@"%@ -> %@", verb, SBTitle(it));
        if (it) SBEnqueue(@[ it ], [verb isEqualToString:@"next"] ? SBModePlayNext : SBModeAddToQueue);
        SBDump();
    } else if ([verb isEqualToString:@"seekend"]) {
        // jump to 4 s before the end of the current song to test natural track changes
        MPAVController *c = SBController();
        double d = [[(id)c valueForKey:@"durationOfCurrentItemIfAvailable"] doubleValue];
        if (d > 6) [(id)c setValue:@(d - 4) forKey:@"currentTime"];
        SBLog(@"seekend: duration %.1f", d);
    } else if ([verb isEqualToString:@"demo"] && parts.count > 1) {
        // demo <fraction>: show the swipe bar on the first visible song row, save a
        // screenshot of the window to shot.png, then clean up.
        CGFloat frac = [parts[1] floatValue];
        NSArray *wins = [UIApplication sharedApplication].windows;
        UIWindow *win = [UIApplication sharedApplication].keyWindow ?: (wins.count ? wins[0] : nil);
        Class mc = objc_getClass("IUMediaTableCell");
        UITableViewCell *cell = nil;
        if (!win || !mc) { SBLog(@"demo: no window (app not on screen)"); return; }
        NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
        while (stack.count && !cell) {
            UIView *v = stack[0];
            [stack removeObjectAtIndex:0];
            if ([v isKindOfClass:mc] && SBItemsForEntity(SBEntityForCell((UITableViewCell *)v)).count && !v.hidden)
                cell = (UITableViewCell *)v;
            [stack addObjectsFromArray:v.subviews];
        }
        SBLog(@"demo: window=%@ cell=%@", win, cell);
        if (cell) {
            SBSwipePan *g = [[SBSwipePan alloc] initWithTarget:nil action:NULL];
            [[SBSwipeHandler shared] begin:g cell:cell];
            [[SBSwipeHandler shared] move:g cell:cell dx:cell.bounds.size.width * frac];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIGraphicsBeginImageContextWithOptions(win.bounds.size, YES, 1);
                [win.layer renderInContext:UIGraphicsGetCurrentContext()];
                UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                [UIImagePNGRepresentation(img) writeToFile:[kSBDir stringByAppendingPathComponent:@"shot.png"] atomically:YES];
                [g.slider removeFromSuperview];
                [g.bar removeFromSuperview];
                SBLog(@"demo: saved shot.png (armed=%d)", g.armed);
            });
        }
    } else if ([verb isEqualToString:@"toast"]) {
        SBToast(@"SiraBende is running");
    }
}

%ctor {
    @autoreleasepool {
        SBLog(@"SiraBende loaded in %@", [[NSBundle mainBundle] bundleIdentifier]);
        int token;
        notify_register_dispatch("com.sirabende.cmd", &token, dispatch_get_main_queue(), ^(int t) {
            SBRunCommand();
        });
    }
}

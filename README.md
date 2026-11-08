# SiraBende

Apple Music–style **Play Next** and **Add to Queue** for the stock **iOS 6** Music app (jailbroken devices).

Swipe a song (or album) row to the right:

| Swipe distance | Action | Bar colour |
|---|---|---|
| ≥ 22 % of the row | **Play Next** – inserted right after the current song | orange |
| ≥ 50 % of the row | **Add to Queue** – appended after the songs already queued | purple |

The row slides over a coloured action bar and a short toast confirms the action
(`Playing Next: …` / `Added to Queue: …`). Swiping an album queues all of its songs.
If nothing is playing, the swiped item simply starts playing.

Tested on an iPod touch 4 (iPod4,1) running iOS 6.1.6.

## How it works

* **Queue engine** – songs are appended to `IUMediaQueryQueueFeeder`'s `prefixMediaItems`
  and mapped to positions right after the current song through a virtual index map, so the
  Music app's own playback machinery (`MPAVController` / `MPQueuePlayer`) creates and plays
  them. Gapless transitions, lock-screen controls and headphone remotes keep working.
  The feeder calls itself recursively (`copyRawItemAtIndex:` → `mediaItemAtIndex:`), so only
  the outermost call is translated (re-entrancy guard).
* **Swipe UI** – a `UIPanGestureRecognizer` is attached to every `IUMediaTableCell`; the
  row's snapshot slides over a coloured bar (the Music app draws rows in its own content
  view, so moving `contentView` alone shows nothing).
* The queue is reset when a new list is started or shuffle is toggled (same as Apple Music).

### Test helper: `sbqctl`

A small command-line tool installed to `/usr/bin/sbqctl` lets you drive and inspect the
queue over SSH without touching the device:

```sh
sbqctl --play | --pause | --next      # transport controls (starts Music in background)
sbqctl --playpid <persistentID>       # play one song and report whether time advances
sbqctl dump                           # log current queue to /var/mobile/Library/Caches/SiraBende/log.txt
sbqctl songs                          # log library songs with persistent IDs
sbqctl next <persistentID>            # Play Next
sbqctl queue <persistentID>           # Add to Queue
sbqctl seekend                        # jump near the end of the current song
```

Run `--playpid` as the `mobile` user (`su mobile -c "sbqctl --playpid …"`).

## Building

Uses [Theos](https://theos.dev) with an armv7-capable toolchain and the iOS 9.3 SDK
(`TARGET := iphone:clang:9.3:6.0`, `ARCHS = armv7`).

```sh
export THEOS=/opt/theos
make package FINALPACKAGE=1
```

On Linux without a prebuilt iOS toolchain, `toolchain/build-toolchain.sh` builds
`ld64` (cctools-port), `libtapi`, `libdispatch` and `ldid` from source and uses the
distribution's `clang-18`; `toolchain/fix-sdk.sh` adds stub `.tbd` files that the 9.3 SDK
lacks. The Makefile passes `--ld-path`, `-fno-modules` and `-fno-exceptions` for that setup.

## Notes

* Never call `MPMusicPlayerController iPodMusicPlayer` synchronously on the Music app's main
  thread from inside the app – the player server lives there and it deadlocks.
* Hooked private classes: `IUMediaQueryQueueFeeder`, `IUTableViewController`,
  `IUiPodAVController`, `MPAVPlaylistManager` (iOS 6 `iPodUI` / `MediaPlayer` frameworks).

## License

MIT – see [LICENSE](LICENSE).

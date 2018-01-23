Browser based MPD client.

With Elm and `display:grid`.

## Build

### Vanilla build

- you need a Go compiler
- run `make`

The binary will be `siren/siren`. It has all resources bundled in the
executable, so you can copy it to other machines.

By default it binds to [*:6601](http://localhost:6601) , and it searches for MPD on localhost. See `./siren --help` to change settings.

### Raspberry Pi build

Thanks to Go's cross-platform support you can build Siren on your laptop, and copy the executable to your Rasberry Pi.

- you need a Go compiler on your laptop
- `(cd build && make build-pi)`
- copy `siren/siren` to your Raspberry Pi
- open http://your_raspberry:6601/

Done, no other files needed.


## Devel

### CSS dev build

If you want to change the CSS, but don't need changes in Elm:

- you need a Go compiler
- `cd siren && make run`
- open http://localhost:6601/

This will uses the files from `./docroot/`. You can change the files in there
and reload your browser.


### Elm + CSS dev build

The compiled .elm files are included in the ./docroot/ directory, so you don't need
an Elm compiler unless you make changes to the Elm code:

- you need a Go and an Elm compiler
- `(cd siren && make run)`
- `cd elm && make`
- open http://localhost:6601/

`make run` serves the files from disk, so you can recompile the elm code and
reload the browser while working on the Elm and CSS code; no need to restart the daemon.


## Links

- [Music Player Daemon](https://www.musicpd.org)
- [Elm](https://elm-lang.org)

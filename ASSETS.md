# Asset attribution & notice

The source code in this repository is MIT-licensed (see [`LICENSE.md`](LICENSE.md)). **That license
applies to the code only — it does *not* cover the GIF artwork in `gifs/`.**

The bundled preset GIFs are third-party content collected from publicly available sources on the
internet (e.g. Giphy, Pinterest) and are included here purely as reference / sample artwork to
demonstrate the app. No ownership is claimed over any of this artwork, and all rights to the
underlying characters and images remain with their respective owners:

- `totoro.gif`, `totoro-white.gif`, `totoro-black.gif`, `totoro-group-white.gif`,
  `totoro-group-black.gif` — "Totoro" and related characters © Studio Ghibli.
- `chihiro-walk.gif`, `chihiro-walk-white.gif`, `chihiro-walk-black.gif` — "Chihiro" (Spirited Away)
  © Studio Ghibli.
- `running-horse-black.gif`, `running-horse-white.gif` — animal silhouette from a public source
  (original authorship unverified).
- `running-dog-white.gif`, `running-dog-black.gif` — animal silhouette from a public source
  (original authorship unverified).

This project is **not affiliated with, endorsed by, or sponsored by** any of these rights holders.
If you are a rights holder and would like a file removed, please open an issue and it will be taken
down promptly.

## Using your own art

You don't need the bundled GIFs — point the app at any GIF you have the rights to use:

```bash
menubar-load-runner /absolute/path/to/your.gif
# or
MENUBAR_LOAD_RUNNER_PATH=/absolute/path/to/your.gif menubar-load-runner
```

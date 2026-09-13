# Sowa Linux artwork

- [logo.svg](logo.svg) is the scalable emblem: a blue and green owl with amber
  eyes, a penguin nestled in its breast, and a circular frame. It has a
  transparent background and a square `512 512` viewBox. All artwork uses
  vector paths and shapes, with no embedded bitmap, font, or external resource.
- [logo-ascii.txt](logo-ascii.txt) is a plain ASCII rendition for terminals,
  banners, and text documentation. Display it in a monospace font and preserve
  its leading spaces. It contains no tabs, Unicode artwork, or ANSI escapes.

The emblem takes its visual cues from
[the supplied reference](Gemini_Generated_Image_l1shjvl1shjvl1sh.jpg).

Display the terminal version from the repository root with:

```sh
cat assets/logo-ascii.txt
```

Embed the vector in a page with an explicit size and descriptive alternative
text, for example:

```html
<img src="assets/logo.svg" alt="Sowa Linux" width="256" height="256">
```

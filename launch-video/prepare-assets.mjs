import { copyFile, mkdir } from "node:fs/promises";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const assets = new URL("./assets/", import.meta.url);
await mkdir(assets, { recursive: true });

// The film uses Sotto's native macOS typography. Resolve installed system
// fonts locally for rendering; their binaries are never distributed in Git.
await Promise.all(
  [
    [require.resolve("gsap/dist/gsap.min.js"), "gsap.min.js"],
    ["/System/Library/Fonts/SFNS.ttf", "sotto-ui.ttf"],
    ["/System/Library/Fonts/Supplemental/Georgia.ttf", "sotto-serif.ttf"],
    [
      "/System/Library/Fonts/Supplemental/Georgia Italic.ttf",
      "sotto-serif-italic.ttf",
    ],
  ].map(([source, name]) => copyFile(source, new URL(name, assets))),
);

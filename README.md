# ClipQueue Web

A dark-mode sequential clipboard queue web app built to run live on **GitHub Pages**.

## Features
- **Float Always-on-Top (`Float ↗`):** Uses the Document Picture-in-Picture API in Microsoft Edge and Google Chrome to pop out into a real always-on-top floating window over your other desktop apps.
- **Collapsible Mini Pill (`▲` / `▼`):** Shrinks down to show only the next item up to be pasted.
- **Auto-Clear on Copy:** Click any item (or **Copy Next →**) to copy it to your clipboard and automatically remove it from the queue.
- **Drag-and-Drop Reorder & Inline Edit:** Drag cards to reorder, double-click to edit, and save automatically in browser `localStorage`.

## How to Host on GitHub Pages
1. Create a new **Public** repository on GitHub (e.g., `ClipQueue-Web`).
2. Upload all files from this ZIP (`index.html`, `manifest.json`, `ClipQueue.ico`, `icon-192.png`, `icon-512.png`, `README.md`) to the root of the repo.
3. Go to **Settings** → **Pages** → set **Source** to **Deploy from a branch** → select **`main`** and **`/ (root)`** → click **Save**.
4. Open `https://YOUR_USERNAME.github.io/ClipQueue-Web/` in Edge or Chrome.

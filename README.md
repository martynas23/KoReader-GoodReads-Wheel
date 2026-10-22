# Goodreads Wheel

A [KOReader](https://github.com/koreader/koreader) plugin that picks your next
book. It syncs your Goodreads **Want to Read** shelf, then spins a slot
machine over it: titles flip past, slow down, and land on one book with its
cover, author, page count and rating. Don't like it? **Spin again**.

## Installation

1. **Download the plugin.** Clone this repository or download it as a ZIP and
   unzip it.

2. **Rename the folder to `goodreadswheel.koplugin`.** KOReader only loads
   plugin folders whose names end in `.koplugin`. The folder must contain
   `_meta.lua`, `main.lua`, `gr_sync.lua` and `gr_wheel.lua` directly.

3. **Copy it into KOReader's `plugins` folder** on your device:

   | Device     | Plugins folder                                    |
   |------------|---------------------------------------------------|
   | Kindle     | `koreader/plugins/` (on the Kindle drive's root)  |
   | Kobo       | `.adds/koreader/plugins/` (hidden folder)         |
   | PocketBook | `applications/koreader/plugins/`                  |
   | Android    | `koreader/plugins/` in internal storage           |

4. **Restart KOReader.**

## Setup

1. **Make your Goodreads profile public.** The plugin reads your shelf through
   Goodreads' public RSS feed, which only works if anyone can see your
   profile: on goodreads.com go to **Settings** → **Privacy** →
   **Who can view my profile** → **anyone**.
2. **Find your user ID.** It's the number in your profile link, e.g.
   `goodreads.com/user/show/12345678-name` → `12345678`.
3. In KOReader open the top menu → **Tools** → **Goodreads wheel** →
   **Set Goodreads user ID**, and enter the number (pasting the whole profile
   link also works). The first sync starts right away.

## Using it

Top menu → **Tools** → **Goodreads wheel**:

- **Spin the wheel**: picks a random book from your synced shelf. Tap
  **Spin again** for another, or tap outside the box to close it. On devices
  with buttons, press the centre button to spin again and **Back** to close.
- **Sync want-to-read**: re-downloads the shelf. Run it after adding books on
  Goodreads. Wi-Fi is turned on if needed. Long-press the item to see when you
  last synced.
- **Goodreads user ID**: switch to a different account. Changing it clears the
  old list and syncs the new one.

Spinning works offline once you've synced. Covers are downloaded the first
time a book wins while Wi-Fi is on, then kept in `koreader/cache/goodreadswheel/`.
Without Wi-Fi a book that hasn't won before shows "No cover".

## Troubleshooting

- **"No books found"**: your profile isn't public, or the Want to Read shelf
  is empty. Check the privacy setting above.
- **"No Goodreads user with ID …"**: the number is wrong. Copy it from your
  profile link again.
- **Sync failed with a timeout**: check the Wi-Fi connection and try again.
  Large shelves download 100 books per page, so a 1000-book shelf takes 10
  requests.

## License

GNU AGPL v3, see [LICENSE](LICENSE).

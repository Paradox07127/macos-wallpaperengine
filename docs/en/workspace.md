# Workspace Guide

**English** · [简体中文](../zh-Hans/workspace.md)

Loomscreen brings display setup and wallpaper browsing into one management
window. Open **Manage** from the menu bar. Close the window when you're done;
wallpapers keep running until you pause them or quit the app.

## Start with a display

**Overview** shows your displays in their desktop arrangement, with wallpaper
covers and playback status. Click a display to open its editor. Drag a supported
video, web folder or Pro scene project onto a display to assign content there.

The overview, wallpaper shelf and expanded library are connected views of the
same collection. Use the shelf for a quick choice or **Wallpaper Library** for
search, filters and a larger grid. Open a wallpaper's detail to inspect it,
apply it by display name, or drag its preview onto a display.

Covers are previews, not a second live wallpaper renderer. Judge playback on
the desktop and by the display's status; a selected cover does not establish
that a new source loaded successfully.

## Find the right page

| Page | Use it for |
|---|---|
| Overview | See display arrangement, playback state and assigned wallpapers |
| Wallpaper Library | Browse imported/saved content, Apple Aerials and installed Workshop content supported by your edition |
| Schemes | Save and restore a whole setup for one display |
| Workshop — Pro | Browse online items, like them for later, download and inspect community presets |
| System Wallpaper — macOS 26+ | Publish supported videos for selection in macOS Wallpaper settings |
| Settings | Change app-wide defaults, performance rules, integrations and maintenance settings |

**System Wallpaper** has its own video-only provider. Its publishing status is
separate from a wallpaper running inside Loomscreen and from the wallpaper
currently selected by macOS.

## Edit wallpaper playback

In the display editor, **Wallpaper** holds playback controls and the source's
inspector. Fit, mute/volume and the frame-rate ceiling belong to that display;
the menu-bar global switch controls all wallpapers.

Video adds speed and color controls. Web adds source, JavaScript, network and
layout options. Pro scenes add author-defined properties and scene presets.
The frame-rate control configures a ceiling; it is not an achieved-FPS meter.

Ordinary property edits save as you interact. **Wallpaper Automation** opens
a draft editor for Playlist, Daily Schedule and Library Shuffle. **Save**
commits the draft; **Cancel** also restores the setup from before trial playback.
See [Quick Start](quick-start.md#4-playlists-and-rotation).

## Arrange overlays

Switch the display editor to **Overlays**. The canvas brings widgets, clock
and music together. Use the layer list to select objects and the object
inspector to adjust them. **Add Widget** opens the palette; click to add at a
free spot or drag onto the canvas to place an object. The palette includes
eleven widget types plus independent music and clock layers.

Move and size objects in the preview. Sample Data helps check layout without
claiming to show current readings. Use the effect layer for particles and
weather response. Runtime windows remain independently owned even though
they share this editor.

With widget interaction enabled, only visible widget areas receive desktop
clicks; empty areas remain click-through. Clock and music controls keep their
own interaction behavior.

## Bookmarks, likes, presets and schemes

| Item | What it saves |
|---|---|
| Yellow bookmark | A mark on an existing library entry; use the Bookmarks filter to find it |
| Pink Workshop like — Pro | An online item to download later; liking does not download, subscribe or apply |
| Scene preset — Pro | Named parameter values for one base scene |
| Display scheme | A whole setup for one display, including wallpaper, overlays and automation |

Removing a bookmark or like removes its mark, not the wallpaper media.
Schemes and `.lwconfig` backups reference local files; they do not bundle media,
credentials or portable file-access grants.

## Settings and guidance

Settings has a grouped sidebar: Setup, Playback, Content, Data and Support.
Search can take you to a matching setting. Per-display wallpaper edits belong
in the display editor; **Display Defaults** defines defaults for display setup.

The floating **Welcome Tour** highlights real controls. Close it with the close
button or Esc to use the page. **Settings → About → Welcome Tour** reopens it;
**Explain This Page** offers contextual guidance. For permissions and recovery,
see [Install](install.md) and [Troubleshooting](troubleshooting.md).

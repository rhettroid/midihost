# MIDI Host

A small native macOS MIDI patchbay. The first MVP discovers CoreMIDI sources and destinations, connects selected inputs to outputs, forwards MIDI packets locally, and shows basic activity.

## Run

Open the folder in Xcode and run the `MIDIHost` executable target, or use:

```sh
./run.sh
```

To create a double-clickable personal-use app bundle:

```sh
./package_app.sh
```

This creates `MIDIHost.app` in the project folder. You can double-click it in Finder or drag it to `/Applications`.

The app targets macOS 11+ and uses only SwiftUI and CoreMIDI.

## Next milestones

1. Add transpose and MIDI clock options per route.
2. Save and restore named routing presets.
3. Add a proper MIDI monitor and menu-bar mode.

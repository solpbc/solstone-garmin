# Changelog

all notable changes to `solstone-garmin` are documented in this file.

## [Unreleased]

### Added

- the app's main screen shows the sun's path across the day behind one control, with a short note only when something needs you, and the session's time, the audio waiting on your watch and the next step one press down.
- a glance and a watch face complication show whether a session is running and open the app, but don't start one.
- initial open-source release of the solstone app for supported Garmin watches with a built-in microphone; phone companion integration in the solstone app on your phone is in progress.
- voice sessions you start from the watch's apps menu or a button shortcut, built to move over Bluetooth through Garmin Connect and the solstone app on your phone into your journal.
- over half an hour of on-watch voice storage when your phone is out of reach; the session stops when storage fills without overwriting audio that has not reached your phone yet, and waiting audio moves oldest first in the background after you close the watch app.

# Talk Assist

This is Flutter project.

Talk Assist 2.0 is a mobile adaptation of Talk Assist 1.0, a voice-based software application that was designed to support visually impaired users. Allocating edge cutting functionalities like accent handling and environmental adaptation. This system will be developed by extending and modifying an existing prototype build by the previous team.

Talk Assist 2.0 will focus on mobile application development, starting with android as the focus point, IOS implementation be considered after significate development process made in android platform. It will be evaluated through usage scenarios to assess its effectiveness and limitations as an assistive tool. Furthermore, offline capability and additional features will be added to post-public test adjustments.

## How this is build

This project is build under flutter framework. The app uses the llamadart Flutter plugin to run Qwen3.5-0.8B Chat GGUF (Q8_0) locally. Virtial Device emulation is supported by Android Studio.

## Current Virtial Device Setup and specs

Emulated Performance Section:

- CPU cores: 4
- Graphics acceleration: Automatic
- RAM: 4 GB
- VM heap size: 336 MB
- Perferred ABI: Optimal

### Ideal spec:

- 4-6 cores mobile CPU
- 4-8 GB of RAMs
- 128 GB of storage space
- LTE-A / 5G internet connectivity, <150 ms latency
- AI accelerator

## To run this project:

First, make sure your have your emulation device up and running. Then,

```
flutter run
```

## To erase chat history:

```
adb shell run-as com.example.talk_assist rm -f app_flutter/history.json
```

## To clear all app data

```
adb shell pm clear com.example.talk_assist
```

This wipes the entire app (SharedPreferences, downloads, everything). The model will re-download on next launch.

## Team 6

By Chaoji Yang, JunWei Zhuo, Kenny Huang, Dylan Walker

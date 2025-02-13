Linphone is an open-source softphone for voice and video over IP calling and instant messaging. It is fully SIP-based, covering all calling, presence, and IM features. A general description is available on the [Linphone website](https://www.linphone.org/technical-corner/linphone).

## License

Copyright © Belledonne Communications

Linphone is dual-licensed and is available either:
- under a [GNU/GPLv3](https://www.gnu.org/licenses/gpl-3.0.en.html) license for free (open source). Please ensure that you understand and agree with the terms of this license before using it (see the LICENSE file for details).
- under a proprietary license, for a fee, for use in closed-source applications. Contact [Belledonne Communications](https://www.linphone.org/contact) for any questions about costs and services.

## Documentation

- Supported features and RFCs: [Linphone Features](https://www.linphone.org/technical-corner/linphone/features)
- Linphone public wiki: [Linphone Wiki](https://wiki.linphone.org/xwiki/wiki/public/view/Linphone/)

# How can I contribute?

Thanks for asking! We love pull requests from everyone. Depending on what you want to do, you can help us improve Linphone in various ways:

## Help on translations

We no longer use Transifex for the translation process. Instead, we have deployed our own instance of [Weblate](https://weblate.linphone.org/projects/linphone-iphone/).

Due to the full app rewrite, we can't reuse previous translations, so we'll be very happy if you want to contribute.

## Report bugs and submit patches

If you want to dig through Linphone code or report a bug, please read `CONTRIBUTING.md` first. You should also read this `README` entirely ;-).

## How to be a beta tester?

Enter the Beta:
- Download TestFlight from the App Store and log in with your Apple ID.
- Tap the public link on your iOS device. The public link: https://testflight.apple.com/join/LUlmZWjH
- Touch View in TestFlight or Start Testing. You can also touch Accept, Install, or Update for the Linphone app.
- Voilà! You can update your beta version with the same public link when a new one is available.

# Send a crash report:
- It is done automatically by TestFlight.

# Report a bug:
- Open Linphone.
- Go to Settings ➔ Advanced ➔ Send logs.
- An email to linphone-iphone@belledonne-communications.com is created with your logs attached.
- Fill in the bug description with:
  * What you were doing.
  * What happened.
  * What you were expecting.
  * Approximately when the bug happened.
- Change the subject to [Beta test - Bug report].
- Send the email.

# Building the application

## What's new:

Now the default way of building Linphone-iPhone is to use CocoaPods to retrieve the Linphone-SDK frameworks.
Compared to previous versions, this project no longer uses submodules; the developer has to build to get a working app.
However, if you wish to use a locally compiled SDK, read the paragraph "Using a local Linphone SDK" below to know how to proceed.

## Building the app

If you don't have CocoaPods already, you can download and install it using :
```
	sudo gem install cocoapods
```
**If you alreadly have Cocoapods, make sure that the version is higher than 1.7.5**.

- Install the app's dependencies with cocoapods first:
```
	pod install
```
  It will download the linphone-sdk from our gitlab repository so you don't have to build anything yourself.
- Then open `linphone.xcworkspace` file (**NOT linphone.xcodeproj**) with XCode to build and run the app.

# Limitations and known bugs

* Video capture will not work in simulator (not implemented in it).


# Using a local linphone SDK

- Clone the linphone-sdk repository from out gitlab:
```
   git clone https://gitlab.linphone.org/BC/public/linphone-sdk.git --recursive
```

- Follow the instructions in the linphone-sdk/README file to build the SDK.

- Rebuild the project:
```
   PODFILE_PATH=<path to linphone-sdk-ios> pod install
```
  where <path to linphone-sdk-ios> is your build directory of the linphone-sdk project, containing the `linphone-sdk.podspec` file and a `linphone-sdk` ouptut directory comprising built frameworks and resources.

- Then open linphone.xcworkspace with Xcode to build and run the app.

# Enabling crashlytics

We've integrated Crashlytics into linphone-iphone, which can automatically send crash reports. It is disabled by default.
To activate it:

- Replace the GoogleService-Info.plist for this project with yours (specific to your crashlytics account).

- Rebuild the project:
```
    USE_CRASHLYTICS=true pod install
```

- Then open `linphone.xcworkspace` with Xcode to build and run the app.

# Quick UI reference

- The app is contained in a window, which resides in the MainStoryboard file.
- The delegate is set to LinphoneAppDelegate in main.m, in the UIApplicationMain() by passing its class
- Basic layout:

        MainStoryboard
                |
                | (rootViewController)
                |
            PhoneMainView ---> view |--> app background
                |                   |
                |                   |--> statusbar background
                |
                | (mainViewController)
                |
            UICompositeView : TPMultilayout
                        |
                        |---> view  |--> statusBar
                                    |
                                    |--> contentView
                                    |
                                    |--> tabBar


When the application is started, the `PhoneMainView` is asked to transition to the Dialer view or the Assistant view. 
`PhoneMainView` exposes the `-changeCurrentView:` method, which will set up any Linphone view that is actually 
presented in the `UICompositeView`, with or without a statusBar and tabBar.

The UICompositeView consists of 3 areas laid out vertically. From top to bottom: StatusBar, Content and TabBar.
The TabBar is usually the UIMainBar, which is used as a navigation controller: clicking on each of the buttons will trigger
a transition to another "view".

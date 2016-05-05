# Overview

**Starred Seach** is a tool to search the readme files in GitHub users' starred repositories. It lives at [starredsearch.com](http://starredsearch.com).

The app is written in Swift using the [Vapor](https://github.com/qutheory/vapor) web framework.

# Prerequisites

Swift build [2016-03-24](https://swift.org/builds/development/xcode/swift-DEVELOPMENT-SNAPSHOT-2016-03-24-a/swift-DEVELOPMENT-SNAPSHOT-2016-03-24-a-osx.pkg) (.pkg download).

A [GitHub OAuth application](https://github.com/settings/developers) with the callback URL set to `/oauth/github` on your server.

# Installation

Clone the repository and set the active Swift toolchain to the 2016-03-24 build.

Run `./vapor build --release` to install package dependencies and build the project.

# Debug Environment

To debug the app in Xcode, create the file `debug.json` in the local root directory:

```
{
  "GITHUB_CLIENT_ID": "<your app client>",
  "GITHUB_CLIENT_SECRET": "<your app secret>",
  "APP_ADMIN_PASSWORD": "<your choice>"
}
```

# Release Environment

Build the app using `./vapor build --release` and copy `.build/release/App` to the server.

Copy the `Resource` and `Public` directories to the same directory on the server.

Add environment variables for `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` and `APP_ADMIN_PASSWORD`.

Run `./App --workDir=<your directory> --port=<your port>`.

# Sample launchctl File

Replace `???` as appropriate.

```
<plist version="1.0">
<dict>
	<key>EnvironmentVariables</key>
	<dict>
    <key>GITHUB_CLIENT_ID</key>
    <string>???</string>
    <key>GITHUB_CLIENT_SECRET</key>
    <string>???</string>
    <key>APP_ADMIN_PASSWORD</key>
    <string>???</string>
	</dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>???</string>
	<key>ProgramArguments</key>
	<array>
		<string>???/App</string>
		<string>--workDir=???</string>
		<string>--port=???</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>???</string>
	<key>StandardOutPath</key>
	<string>???</string>
	<key>WorkingDirectory</key>
	<string>???</string>
</dict>
</plist>
```
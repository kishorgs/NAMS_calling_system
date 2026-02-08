# Firebase Setup Instructions

## 1. Create Firebase Project
1. Go to https://console.firebase.google.com/
2. Click "Create a project"
3. Enter project name and follow setup steps
4. Enable Authentication with Email/Password

## 2. Android Setup
1. Add Android app in Firebase console
2. Package name: `com.example.nams_calling_system`
3. Download `google-services.json`
4. Replace the template file at `android/app/google-services.json`
5. Add to `android/build.gradle`:
   ```gradle
   dependencies {
       classpath 'com.google.gms:google-services:4.3.15'
   }
   ```
6. Add to `android/app/build.gradle`:
   ```gradle
   apply plugin: 'com.google.gms.google-services'
   ```

## 3. iOS Setup
1. Add iOS app in Firebase console
2. Bundle ID: `com.example.namsCallingSystem`
3. Download `GoogleService-Info.plist`
4. Replace the template file at `ios/Runner/GoogleService-Info.plist`

## 4. Enable Authentication
1. In Firebase console, go to Authentication
2. Click "Get started"
3. Go to "Sign-in method" tab
4. Enable "Email/Password"

## 5. Excel File Format
Create Excel file with column header "phone_number" in first column:
```
phone_number
9036022320
9353636398
```
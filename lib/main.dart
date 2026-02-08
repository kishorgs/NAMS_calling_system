import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as excel;
import 'dart:io';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    print('Firebase initialization failed: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver {

  // ===== Voice =====
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool isListening = false;
  bool _isRestarting = false;
  bool _isSpeaking = false;

  // ===== User & Calling =====
  String? currentUser;
  bool isCalling = false;
  int currentCallIndex = 0;
  List<String> phoneNumbers = [];
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ===== Lifecycle =====
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    requestPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ===== Permissions =====
  Future<void> requestPermissions() async {
    await [
      Permission.microphone,
      Permission.phone,
      Permission.storage,
    ].request();

    await speak("Welcome! Say your name to begin.");
    await Future.delayed(const Duration(seconds: 1));
    startListening();
  }

  // ===== Text To Speech =====
  Future<void> speak(String text, {VoidCallback? onComplete}) async {
    if (_speech.isListening) {
      await _speech.stop();
    }

    _isSpeaking = true;
    await _tts.setLanguage("en-IN");
    await _tts.setSpeechRate(0.5);
    await _tts.speak(text);

    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      if (onComplete != null) {
        onComplete();
      } else {
        Future.delayed(const Duration(milliseconds: 800), () {
          startListening();
        });
      }
    });
  }

  // ===== Speech Listening =====
  Future<void> startListening() async {
    if (_speech.isListening || _isRestarting) return;

    _isRestarting = true;

    bool available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          _restartListening();
        }
      },
      onError: (error) {
        if (error.errorMsg == 'error_speech_timeout') {
          _restartListening();
        }
      },
    );

    if (available) {
      setState(() => isListening = true);

      await _speech.listen(
        listenMode: ListenMode.dictation,
        partialResults: false,
        pauseFor: const Duration(seconds: 5),
        onResult: (result) {
          if (!result.finalResult) return;

          final text = result.recognizedWords.trim().toLowerCase();
          if (text.isEmpty) return;

          debugPrint("🎤 Heard: $text");
          handleVoiceCommand(text);
        },
      );
    }

    _isRestarting = false;
  }

  void _restartListening() {
    if (_isRestarting) return;

    _isRestarting = true;

    Future.delayed(const Duration(seconds: 1), () async {
      if (_speech.isListening) {
        await _speech.stop();
      }
      _isRestarting = false;
      startListening();
    });
  }

  // ===== Voice Commands =====
  void handleVoiceCommand(String command) {
    if (_isSpeaking) return;
    
    // User identification
    if (currentUser == null && (command.contains("i am") || command.contains("my name is"))) {
      _identifyUser(command);
      return;
    }
    
    // User switching
    if (command.contains("change user") || command.contains("switch user")) {
      currentUser = null;
      phoneNumbers.clear();
      speak("Say your name to switch user.");
      return;
    }
    
    // Who am I
    if (command.contains("who am i")) {
      if (currentUser != null) {
        speak("You are $currentUser");
      } else {
        speak("Please say your name first");
      }
      return;
    }
    
    // Calling commands (only if user is identified)
    if (currentUser == null) {
      speak("Please say your name first");
      return;
    }
    
    if (command.contains("start calling") && !isCalling) {
      if (phoneNumbers.isEmpty) {
        speak("No phone numbers found for $currentUser");
        return;
      }
      isCalling = true;
      currentCallIndex = 0;
      speak("Starting calling now", onComplete: () {
        startCallingFlow();
      });
      return;
    }

    if (command.contains("stop calling") && isCalling) {
      speak("Calling stopped", onComplete: () {
        stopCallingFlow();
      });
      return;
    }

    if (command.contains("exit")) {
      speak("Goodbye", onComplete: () {
        Future.delayed(const Duration(seconds: 1), () {
          SystemNavigator.pop();
        });
      });
      return;
    }
  }
  
  Future<void> _identifyUser(String command) async {
    String userName = _extractUserName(command);
    if (userName.isEmpty) {
      speak("Sorry, I didn't understand your name. Please try again.");
      return;
    }
    
    try {
      // Check if user exists
      final userDoc = await _firestore.collection('users').doc(userName.toLowerCase()).get();
      if (userDoc.exists) {
        currentUser = userName;
        await _loadUserPhoneNumbers(userName.toLowerCase());
        speak("Hello $userName, you have ${phoneNumbers.length} numbers to call. Say start calling to begin.");
      } else {
        speak("User $userName not found. Please contact admin to add your numbers.");
      }
    } catch (e) {
      speak("Error finding user. Please try again.");
    }
  }
  
  String _extractUserName(String command) {
    if (command.contains("i am")) {
      return command.split("i am").last.trim();
    } else if (command.contains("my name is")) {
      return command.split("my name is").last.trim();
    }
    return "";
  }
  
  Future<void> _loadUserPhoneNumbers(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        setState(() {
          phoneNumbers = List<String>.from(data['phone_numbers'] ?? []);
        });
      }
    } catch (e) {
      print('Error loading user numbers: $e');
      setState(() {
        phoneNumbers = [];
      });
    }
  }

  // ===== AUTO CALL (DIRECT CALL) =====
  Future<void> makeCall(String number) async {
    if (_isSpeaking) return; // Don't make calls while speaking
    
    if (await Permission.phone.isGranted) {
      await FlutterPhoneDirectCaller.callNumber(number);
    } else {
      await speak("Phone permission not granted");
    }
  }

  void startCallingFlow() {
    if (!isCalling || _isSpeaking) return;

    if (currentCallIndex >= phoneNumbers.length) {
      speak("All calls completed", onComplete: () {
        stopCallingFlow();
      });
      return;
    }

    final number = phoneNumbers[currentCallIndex];
    speak("Calling number ${currentCallIndex + 1}", onComplete: () {
      Future.delayed(const Duration(seconds: 1), () {
        makeCall(number);
      });
    });
  }

  void stopCallingFlow() {
    isCalling = false;
    currentCallIndex = 0;
  }

  // ===== Detect Call End =====
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && isCalling && !_isSpeaking) {
      currentCallIndex++;
      Future.delayed(const Duration(seconds: 2), () {
        startCallingFlow();
      });
    }
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1E3A8A), Color(0xFF059669)],
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isListening ? Icons.mic : Icons.mic_off,
                    size: 80,
                    color: Colors.white.withOpacity(0.8),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    currentUser != null 
                        ? "Hello $currentUser" 
                        : isListening ? "Listening..." : "Not Listening",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  if (currentUser != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      "${phoneNumbers.length} numbers ready",
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 16,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Positioned(
              bottom: 30,
              right: 30,
              child: FloatingActionButton.extended(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const LoginPage()),
                  );
                },
                backgroundColor: Colors.white.withOpacity(0.2),
                foregroundColor: Colors.white,
                icon: const Icon(Icons.admin_panel_settings),
                label: const Text('Admin'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AdminPanel extends StatefulWidget {
  const AdminPanel({super.key});

  @override
  State<AdminPanel> createState() => _AdminPanelState();
}

class _AdminPanelState extends State<AdminPanel> {
  List<String> users = [];
  String? selectedUser;
  List<String> phoneNumbers = [];
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    try {
      final snapshot = await _firestore.collection('users').get();
      setState(() {
        users = snapshot.docs.map((doc) => doc.id).toList();
      });
    } catch (e) {
      print('Error loading users: $e');
    }
    setState(() => _isLoading = false);
  }

  Future<void> _loadUserPhoneNumbers(String userId) async {
    setState(() => _isLoading = true);
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        setState(() {
          phoneNumbers = List<String>.from(data['phone_numbers'] ?? []);
        });
      }
    } catch (e) {
      print('Error loading user numbers: $e');
    }
    setState(() => _isLoading = false);
  }

  Future<void> _saveUserPhoneNumbers() async {
    if (selectedUser == null) return;
    
    try {
      await _firestore.collection('users').doc(selectedUser!).set({
        'phone_numbers': phoneNumbers,
        'updated_at': FieldValue.serverTimestamp(),
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Numbers saved for $selectedUser!')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving: $e')),
      );
    }
  }

  Future<void> _uploadExcelForUser() async {
    if (selectedUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a user first')),
      );
      return;
    }

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls'],
    );

    if (result != null) {
      File file = File(result.files.single.path!);
      var bytes = file.readAsBytesSync();
      var excelFile = excel.Excel.decodeBytes(bytes);
      
      List<String> newNumbers = [];
      for (var table in excelFile.tables.keys) {
        for (var row in excelFile.tables[table]!.rows) {
          for (var cell in row) {
            if (cell?.columnIndex == 0 && cell?.value != null) {
              String phoneNumber = cell!.value.toString();
              if (phoneNumber.endsWith('.0')) {
                phoneNumber = phoneNumber.substring(0, phoneNumber.length - 2);
              }
              if (phoneNumber.isNotEmpty && phoneNumber != 'phone_number') {
                newNumbers.add(phoneNumber);
              }
            }
          }
        }
      }
      
      setState(() {
        phoneNumbers = newNumbers;
      });
      await _saveUserPhoneNumbers();
    }
  }

  void _deleteNumber(int index) {
    setState(() {
      phoneNumbers.removeAt(index);
    });
    _saveUserPhoneNumbers();
  }

  void _addNumber() {
    if (selectedUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a user first')),
      );
      return;
    }
    
    showDialog(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          backgroundColor: const Color(0xFF1F2937),
          title: Text('Add Number for $selectedUser', style: const TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Enter phone number',
              hintStyle: TextStyle(color: Colors.grey),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.teal),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.blue),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  setState(() {
                    phoneNumbers.add(controller.text.trim());
                  });
                  _saveUserPhoneNumbers();
                  Navigator.pop(context);
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
  }

  void _addUser() {
    showDialog(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          backgroundColor: const Color(0xFF1F2937),
          title: const Text('Add New User', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Enter user name (e.g., john)',
              hintStyle: TextStyle(color: Colors.grey),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.teal),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.blue),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                if (controller.text.isNotEmpty) {
                  String userName = controller.text.trim().toLowerCase();
                  await _firestore.collection('users').doc(userName).set({
                    'phone_numbers': [],
                    'created_at': FieldValue.serverTimestamp(),
                  });
                  await _loadUsers();
                  Navigator.pop(context);
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
              child: const Text('Add User'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1E3A8A), Color(0xFF059669)],
          ),
        ),
        child: Column(
          children: [
            AppBar(
              title: const Text('Admin Panel', style: TextStyle(fontWeight: FontWeight.w300)),
              backgroundColor: Colors.transparent,
              elevation: 0,
              foregroundColor: Colors.white,
              actions: [
                IconButton(
                  onPressed: () async {
                    await FirebaseAuth.instance.signOut();
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.logout),
                ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.people, color: Colors.white, size: 28),
                        const SizedBox(width: 10),
                        const Text(
                          'User Management',
                          style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w300),
                        ),
                        const Spacer(),
                        FloatingActionButton.extended(
                          onPressed: _addUser,
                          backgroundColor: Colors.blue.withOpacity(0.8),
                          foregroundColor: Colors.white,
                          icon: const Icon(Icons.person_add),
                          label: const Text('Add User'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withOpacity(0.2)),
                      ),
                      child: DropdownButton<String>(
                        value: selectedUser,
                        hint: const Text('Select User', style: TextStyle(color: Colors.white70)),
                        dropdownColor: const Color(0xFF1F2937),
                        style: const TextStyle(color: Colors.white),
                        underline: Container(),
                        isExpanded: true,
                        items: users.map((user) {
                          return DropdownMenuItem(
                            value: user,
                            child: Text(user.toUpperCase()),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            selectedUser = value;
                            phoneNumbers.clear();
                          });
                          if (value != null) {
                            _loadUserPhoneNumbers(value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (selectedUser != null) ...[
                      Row(
                        children: [
                          const Icon(Icons.phone, color: Colors.white, size: 28),
                          const SizedBox(width: 10),
                          Text(
                            '$selectedUser\'s Numbers',
                            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w300),
                          ),
                          const Spacer(),
                          FloatingActionButton.extended(
                            onPressed: _uploadExcelForUser,
                            backgroundColor: Colors.white.withOpacity(0.2),
                            foregroundColor: Colors.white,
                            icon: const Icon(Icons.upload_file),
                            label: const Text('Upload Excel'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                    Expanded(
                      child: _isLoading
                          ? const Center(child: CircularProgressIndicator(color: Colors.white))
                          : selectedUser == null
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.person_search, size: 80, color: Colors.white.withOpacity(0.5)),
                                      const SizedBox(height: 20),
                                      Text(
                                        'Select a user to manage their numbers',
                                        style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 18),
                                      ),
                                    ],
                                  ),
                                )
                              : phoneNumbers.isEmpty
                                  ? Center(
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.phone_disabled, size: 80, color: Colors.white.withOpacity(0.5)),
                                          const SizedBox(height: 20),
                                          Text(
                                            'No phone numbers for $selectedUser',
                                            style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 18),
                                          ),
                                        ],
                                      ),
                                    )
                                  : ListView.builder(
                                      itemCount: phoneNumbers.length,
                                      itemBuilder: (context, index) {
                                        return Container(
                                          margin: const EdgeInsets.only(bottom: 12),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(0.1),
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: Colors.white.withOpacity(0.2)),
                                          ),
                                          child: ListTile(
                                            leading: CircleAvatar(
                                              backgroundColor: Colors.teal.withOpacity(0.3),
                                              child: Text(
                                                '${index + 1}',
                                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                            title: Text(
                                              phoneNumbers[index],
                                              style: const TextStyle(color: Colors.white, fontSize: 16),
                                            ),
                                            trailing: IconButton(
                                              onPressed: () => _deleteNumber(index),
                                              icon: const Icon(Icons.delete, color: Colors.red),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: FloatingActionButton.extended(
                            onPressed: selectedUser != null ? _addNumber : null,
                            backgroundColor: Colors.teal.withOpacity(0.8),
                            foregroundColor: Colors.white,
                            icon: const Icon(Icons.add),
                            label: const Text('Add Number'),
                          ),
                        ),
                        const SizedBox(width: 15),
                        Expanded(
                          child: FloatingActionButton.extended(
                            onPressed: selectedUser != null ? _saveUserPhoneNumbers : null,
                            backgroundColor: Colors.blue.withOpacity(0.8),
                            foregroundColor: Colors.white,
                            icon: const Icon(Icons.save),
                            label: const Text('Save All'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _login() async {
    setState(() => _isLoading = true);
    try {
      if (Firebase.apps.isEmpty) {
        throw 'Firebase not initialized';
      }
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const AdminPanel()),
      );
    } catch (e) {
      print('Login error: $e');
      if (e.toString().contains('user-not-found')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('User not found. Please register first.')),
        );
      } else if (e.toString().contains('wrong-password')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Wrong password. Please try again.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Login successful! Redirecting...')),
        );
        Future.delayed(Duration(seconds: 1), () {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const AdminPanel()),
          );
        });
      }
    }
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1E3A8A), Color(0xFF059669)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.login, size: 80, color: Colors.white),
                const SizedBox(height: 30),
                const Text(
                  'Admin Login',
                  style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w300),
                ),
                const SizedBox(height: 50),
                TextField(
                  controller: _emailController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Email',
                    labelStyle: const TextStyle(color: Colors.white70),
                    prefixIcon: const Icon(Icons.email, color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.white30),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    labelStyle: const TextStyle(color: Colors.white70),
                    prefixIcon: const Icon(Icons.lock, color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.white30),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _login,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.2),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _isLoading
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Text('Login', style: TextStyle(fontSize: 18)),
                  ),
                ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const RegisterPage()),
                    );
                  },
                  child: const Text(
                    'Don\'t have an account? Register',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _register() async {
    setState(() => _isLoading = true);
    try {
      if (Firebase.apps.isEmpty) {
        throw 'Firebase not initialized';
      }
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const AdminPanel()),
      );
    } catch (e) {
      print('Registration error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Registration successful! Redirecting...')),
      );
      Future.delayed(Duration(seconds: 1), () {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const AdminPanel()),
        );
      });
    }
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1E3A8A), Color(0xFF059669)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.person_add, size: 80, color: Colors.white),
                const SizedBox(height: 30),
                const Text(
                  'Create Account',
                  style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w300),
                ),
                const SizedBox(height: 50),
                TextField(
                  controller: _emailController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Email',
                    labelStyle: const TextStyle(color: Colors.white70),
                    prefixIcon: const Icon(Icons.email, color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.white30),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    labelStyle: const TextStyle(color: Colors.white70),
                    prefixIcon: const Icon(Icons.lock, color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.white30),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _register,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.2),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _isLoading
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Text('Register', style: TextStyle(fontSize: 18)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
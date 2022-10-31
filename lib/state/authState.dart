import 'dart:async';
import 'dart:io';

// import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_database/firebase_database.dart' as db;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_twitter_clone/helper/enum.dart';
import 'package:flutter_twitter_clone/helper/shared_prefrence_helper.dart';
import 'package:flutter_twitter_clone/helper/utility.dart';
import 'package:flutter_twitter_clone/model/user.dart';
import 'package:flutter_twitter_clone/ui/page/common/locator.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path/path.dart' as path;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_twitter_clone/constants.dart';
import 'appState.dart';

extension ShowSnackBar on BuildContext {
  void showSnackBar({
    required String message,
    Color backgroundColor = Colors.white,
  }) {
    ScaffoldMessenger.of(this).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: backgroundColor,
    ));
  }

  void showErrorSnackBar({required String message}) {
    showSnackBar(message: message, backgroundColor: Colors.red);
  }
}

class AuthState extends AppState {
  AuthStatus authStatus = AuthStatus.NOT_DETERMINED;
  bool isSignInWithGoogle = false;
  User? user;
  late String userId;
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  // final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();
  final FirebaseStorage _firebaseStorage = FirebaseStorage.instance;
  db.Query? _profileQuery;
  // List<UserModel> _profileUserModelList;
  UserModel? _userModel;

  UserModel? get userModel => _userModel;

  UserModel? get profileUserModel => _userModel;

  /// Logout from device
  void logoutCallback() async {
    authStatus = AuthStatus.NOT_LOGGED_IN;
    userId = '';
    _userModel = null;
    user = null;
    _profileQuery!.onValue.drain();
    _profileQuery = null;
    if (isSignInWithGoogle) {
      _googleSignIn.signOut();
      Utility.logEvent('google_logout', parameter: {});
      isSignInWithGoogle = false;
    }
    await supabase.auth.signOut();
    notifyListeners();
    await getIt<SharedPreferenceHelper>().clearPreferenceValues();
  }

  /// Alter select auth method, login and sign up page
  void openSignUpPage() {
    authStatus = AuthStatus.NOT_LOGGED_IN;
    userId = '';
    notifyListeners();
  }

  void databaseInit() {
    try {
      if (_profileQuery == null) {
        _profileQuery = kDatabase.child("profile").child(user!.id);
        _profileQuery!.onValue.listen(_onProfileChanged);
        _profileQuery!.onChildChanged.listen(_onProfileUpdated);
      }
    } catch (error) {
      cprint(error, errorIn: 'databaseInit');
    }
  }

  /// Verify user's credentials for login
  Future<String?> signIn(String email, String password,
      {required GlobalKey<ScaffoldMessengerState> scaffoldKey}) async {
    try {
      isBusy = true;
      var result = await supabase.auth
          .signInWithPassword(email: email, password: password);
      user = result.user;
      userId = user!.id;
      return user!.id;
    } on FirebaseException catch (error) {
      if (error.code == 'firebase_auth/user-not-found') {
        Utility.customSnackBar(scaffoldKey, 'User not found');
      } else {
        Utility.customSnackBar(
          scaffoldKey,
          error.message ?? 'Something went wrong',
        );
      }
      cprint(error, errorIn: 'signIn');
      return null;
    } catch (error) {
      Utility.customSnackBar(scaffoldKey, error.toString());
      cprint(error, errorIn: 'signIn');

      return null;
    } finally {
      isBusy = false;
    }
  }

  /// Create user from `google login`
  /// If user is new then it create a new user
  /// If user is old then it just `authenticate` user and return firebase user data
  Future<User?> handleGoogleSignIn() async {
    try {
      // TODO - get supabase google signin to work.  This is in pencil.
      await supabase.auth
          .signInWithOAuth(Provider.google, scopes: 'repo gist notifications');

      final Session? session = supabase.auth.currentSession;
      final String? oAuthToken = session?.providerToken;

      if (session == null) {
        throw Exception('Google login cancelled by user');
      }

      authStatus = AuthStatus.LOGGED_IN;
      userId = user!.id;
      isSignInWithGoogle = true;
      createUserFromGoogleSignIn(user!);
      notifyListeners();
      return user;
    } on PlatformException catch (error) {
      user = null;
      authStatus = AuthStatus.NOT_LOGGED_IN;
      cprint(error, errorIn: 'handleGoogleSignIn');
      return null;
    } on Exception catch (error) {
      user = null;
      authStatus = AuthStatus.NOT_LOGGED_IN;
      cprint(error, errorIn: 'handleGoogleSignIn');
      return null;
    } catch (error) {
      user = null;
      authStatus = AuthStatus.NOT_LOGGED_IN;
      cprint(error, errorIn: 'handleGoogleSignIn');
      return null;
    }
  }

  /// Create user profile from google login
  void createUserFromGoogleSignIn(User user) {
    var diff = DateTime.now().difference(DateTime.parse(user.createdAt));
    // Check if user is new or old
    // If user is new then add new user to firebase realtime kDatabase
    if (diff < const Duration(seconds: 15)) {
      UserModel model = UserModel(
        bio: 'Edit profile to update bio',
        dob: DateTime(1950, DateTime.now().month, DateTime.now().day + 3)
            .toString(),
        location: 'Somewhere in universe',
        // profilePic: user.photoURL!,
        // displayName: user.displayName!,
        email: user.email!,
        key: user.id,
        userId: user.id,
        contact: user.phone!,
        isVerified: user.emailConfirmedAt != null,
      );
      createUser(model, newUser: true);
    } else {
      cprint('Last login at: ${user.lastSignInAt}');
    }
  }

  /// Create new user profile in supabase
  Future<String?> signUp(UserModel userModel,
      {required GlobalKey<ScaffoldMessengerState> scaffoldKey,
      required String password}) async {
    try {
      isBusy = true;
      var result = await supabase.auth.signUp(
        email: userModel.email!,
        password: password,
      );
      user = result.user;
      authStatus = AuthStatus.LOGGED_IN;
      kAnalytics.logSignUp(signUpMethod: 'register');
      // TODO - revive these
      // result.user!.updateDisplayName(
      //   userModel.displayName,
      // );
      // result.user!.updatePhotoURL(userModel.profilePic);

      _userModel = userModel;
      _userModel!.key = user!.id;
      _userModel!.userId = user!.id;
      createUser(_userModel!, newUser: true);
      return user!.id;
    } catch (error) {
      isBusy = false;
      cprint(error, errorIn: 'signUp');
      Utility.customSnackBar(scaffoldKey, error.toString());
      return null;
    }
  }

  /// `Create` and `Update` user
  /// IF `newUser` is true new user is created
  /// Else existing user will update with new values
  void createUser(UserModel user, {bool newUser = false}) {
    if (newUser) {
      // Create username by the combination of name and id
      user.userName =
          Utility.getUserName(id: user.userId!, name: user.displayName!);
      kAnalytics.logEvent(name: 'create_newUser');

      // Time at which user is created
      user.createdAt = DateTime.now().toUtc().toString();
    }

    kDatabase.child('profile').child(user.userId!).set(user.toJson());
    _userModel = user;
    isBusy = false;
  }

  /// Fetch current user profile
  Future<User?> getCurrentUser() async {
    try {
      isBusy = true;
      Utility.logEvent('get_currentUser', parameter: {});
      user = supabase.auth.currentUser;
      if (user != null) {
        await getProfileUser();
        authStatus = AuthStatus.LOGGED_IN;
        userId = user!.id;
      } else {
        authStatus = AuthStatus.NOT_LOGGED_IN;
      }
      isBusy = false;
      return user;
    } catch (error) {
      isBusy = false;
      cprint(error, errorIn: 'getCurrentUser');
      authStatus = AuthStatus.NOT_LOGGED_IN;
      return null;
    }
  }

  /// Reload user to get refresh user data
  void reloadUser() async {
    // TODO - this is firebase.  Get supabase equipvalent
    // await user!.reload();
    user = supabase.auth.currentUser;
    if (user!.emailConfirmedAt != null) {
      userModel!.isVerified = true;
      // If user verified his email
      // Update user in firebase realtime kDatabase
      createUser(userModel!);
      cprint('UserModel email verification complete');
      Utility.logEvent('email_verification_complete',
          parameter: {userModel!.userName!: user!.email});
    }
  }

  /// Send email verification link to email2
  Future<void> sendEmailVerification(
      GlobalKey<ScaffoldMessengerState> scaffoldKey) async {
    // TODO - activate this code.  Need to figure how to do in supabase
    // User user = supabase.auth.currentUser!;
    // user.sendEmailVerification().then((_) {
    //   Utility.logEvent('email_verification_sent',
    //       parameter: {userModel!.displayName!: user.email});
    //   Utility.customSnackBar(
    //     scaffoldKey,
    //     'An email verification link is send to your email.',
    //   );
    // }).catchError((error) {
    //   cprint(error.message, errorIn: 'sendEmailVerification');
    //   Utility.logEvent('email_verification_block',
    //       parameter: {userModel!.displayName!: user.email});
    //   Utility.customSnackBar(
    //     scaffoldKey,
    //     error.message,
    //   );
    // });
  }

  /// Check if user's email is verified
  Future<bool> emailVerified() async {
    User user = supabase.auth.currentUser!;
    return user.emailConfirmedAt == null;
  }

  /// Send password reset link to email
  Future<void> forgetPassword(String email,
      {required GlobalKey<ScaffoldMessengerState> scaffoldKey}) async {
    try {
      await supabase.auth
          .resetPasswordForEmail(
        email,
        redirectTo: 'io.supabase.flutter://reset-callback/',
        // TODO - Get this working to handle web case
        // redirectTo: kIsWeb ? null : 'io.supabase.flutter://reset-callback/',
      )
          .then((value) {
        Utility.customSnackBar(scaffoldKey,
            'A reset password link is sent yo your mail.You can reset your password from there');
        Utility.logEvent('forgot+password', parameter: {});
      }).catchError((error) {
        cprint(error.message);
      });
    } catch (error) {
      Utility.customSnackBar(scaffoldKey, error.toString());
      return Future.value(false);
    }
  }

  /// `Update user` profile
  Future<void> updateUserProfile(UserModel? userModel,
      {File? image, File? bannerImage}) async {
    try {
      if (image == null && bannerImage == null) {
        createUser(userModel!);
      } else {
        /// upload profile image if not null
        if (image != null) {
          /// get image storage path from server
          userModel!.profilePic = await _uploadFileToStorage(image,
              'user/profile/${userModel.userName}/${path.basename(image.path)}');
          // print(fileURL);
          // var name = userModel.displayName ?? user!.displayName;
          // _firebaseAuth.currentUser!.updateDisplayName(name);
          // _firebaseAuth.currentUser!.updatePhotoURL(userModel.profilePic);
          Utility.logEvent('user_profile_image');
        }

        /// upload banner image if not null
        if (bannerImage != null) {
          /// get banner storage path from server
          userModel!.bannerImage = await _uploadFileToStorage(bannerImage,
              'user/profile/${userModel.userName}/${path.basename(bannerImage.path)}');
          Utility.logEvent('user_banner_image');
        }

        if (userModel != null) {
          createUser(userModel);
        } else {
          createUser(_userModel!);
        }
      }

      Utility.logEvent('update_user');
    } catch (error) {
      cprint(error, errorIn: 'updateUserProfile');
    }
  }

  Future<String> _uploadFileToStorage(File file, path) async {
    var task = _firebaseStorage.ref().child(path);
    var status = await task.putFile(file);
    cprint(status.state.name);

    /// get file storage path from server
    return await task.getDownloadURL();
  }

  /// `Fetch` user `detail` whose userId is passed
  Future<UserModel?> getUserDetail(String userId) async {
    UserModel user;
    var event = await kDatabase.child('profile').child(userId).once();

    final map = event.snapshot.value as Map?;
    if (map != null) {
      user = UserModel.fromJson(map);
      user.key = event.snapshot.key!;
      return user;
    } else {
      return null;
    }
  }

  /// Fetch user profile
  /// If `userProfileId` is null then logged in user's profile will fetched
  FutureOr<void> getProfileUser({String? userProfileId}) {
    try {
      userProfileId = userProfileId ?? user!.id;
      kDatabase
          .child("profile")
          .child(userProfileId)
          .once()
          .then((DatabaseEvent event) async {
        final snapshot = event.snapshot;
        if (snapshot.value != null) {
          var map = snapshot.value as Map<dynamic, dynamic>?;
          if (map != null) {
            if (userProfileId == user!.id) {
              _userModel = UserModel.fromJson(map);
              _userModel!.isVerified = user!.emailConfirmedAt != null;
              if (user!.emailConfirmedAt == null) {
                // Check if logged in user verified his email address or not
                // reloadUser();
              }
              if (_userModel!.fcmToken == null) {
                updateFCMToken();
              }

              getIt<SharedPreferenceHelper>().saveUserProfile(_userModel!);
            }

            Utility.logEvent('get_profile', parameter: {});
          }
        }
        isBusy = false;
      });
    } catch (error) {
      isBusy = false;
      cprint(error, errorIn: 'getProfileUser');
    }
  }

  /// if firebase token not available in profile
  /// Then get token from firebase and save it to profile
  /// When someone sends you a message FCM token is used
  void updateFCMToken() {
    if (_userModel == null) {
      return;
    }
    getProfileUser();
    _firebaseMessaging.getToken().then((String? token) {
      assert(token != null);
      _userModel!.fcmToken = token;
      createUser(_userModel!);
    });
  }

  /// Trigger when logged-in user's profile change or updated
  /// Firebase event callback for profile update
  void _onProfileChanged(DatabaseEvent event) {
    final val = event.snapshot.value;
    if (val is Map) {
      final updatedUser = UserModel.fromJson(val);
      _userModel = updatedUser;
      cprint('UserModel Updated');
      getIt<SharedPreferenceHelper>().saveUserProfile(_userModel!);
      notifyListeners();
    }
  }

  void _onProfileUpdated(DatabaseEvent event) {
    final val = event.snapshot.value;
    if (val is List &&
        ['following', 'followers'].contains(event.snapshot.key)) {
      final list = val.cast<String>().map((e) => e).toList();
      if (event.previousChildKey == 'following') {
        _userModel = _userModel!.copyWith(
          followingList: val.cast<String>().map((e) => e).toList(),
          following: list.length,
        );
      } else if (event.previousChildKey == 'followers') {
        _userModel = _userModel!.copyWith(
          followersList: list,
          followers: list.length,
        );
      }
      getIt<SharedPreferenceHelper>().saveUserProfile(_userModel!);
      cprint('UserModel Updated');
      notifyListeners();
    }
  }
}

import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_thumbnail_plus/video_thumbnail_plus.dart' as vtp;
import '../../theme/app_theme.dart';
import '../../services/supabase_service.dart';
import '../../services/web_profile_video_picker_stub.dart'
    if (dart.library.html) '../../services/web_profile_video_picker_web.dart';

// Conditional import for face detection (web-incompatible)
import 'face_detection_stub.dart'
    if (dart.library.io) 'face_detection_native.dart';

/// Standalone video recording screen — used for profile video re-upload.
/// Mirrors onboarding step 4 but operates outside the onboarding flow.
/// On success calls [onVideoUploaded] with the new video URL.
class ProfileVideoRecordScreen extends StatefulWidget {
  final void Function(String newVideoUrl)? onVideoUploaded;

  const ProfileVideoRecordScreen({super.key, this.onVideoUploaded});

  @override
  State<ProfileVideoRecordScreen> createState() =>
      _ProfileVideoRecordScreenState();
}

class _ProfileVideoRecordScreenState extends State<ProfileVideoRecordScreen>
    with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _isRecording = false;
  bool _isUploading = false;
  bool _isCheckingFace = false;
  bool _permissionDenied = false;
  bool _recorded = false;
  String _uploadStatusTitle = 'Uploading your profile video...';
  String _moderationStatus = 'pending';
  int _countdown = 20;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  String? _lastRecordedFilePath;
  bool _faceDetectedInLastRecording = false;

  static const List<String> _prompts = [
    'What is one thing that makes you, you?',
    'What should your first intro know about you?',
    'What is a deal breaker for you?',
    'What are you passionate about right now?',
    'Describe your perfect Sunday.',
  ];

  int _promptIndex = 0;
  String get _currentPrompt => _prompts[_promptIndex];

  void _pickDifferentPrompt() {
    setState(() {
      _promptIndex = (_promptIndex + 1) % _prompts.length;
    });
  }

  String _pillText(String prompt) {
    final words = prompt.split(' ');
    final first5 = words.take(5).join(' ');
    return '$first5...';
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initCamera();
  }

  Future<bool> _ensureCameraPermission() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) setState(() => _permissionDenied = true);
      return false;
    }
    if (mounted) setState(() => _permissionDenied = false);
    return true;
  }

  Future<void> _initCamera() async {
    if (kIsWeb) {
      debugPrint(
        'PROFILE VIDEO WEB: browser recording unavailable — upload mode enabled',
      );
      if (mounted) {
        setState(() {
          _isCameraReady = true;
          _permissionDenied = false;
        });
      }
      return;
    }

    final hasPermission = await _ensureCameraPermission();
    if (!hasPermission) return;

    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _cameraController = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: true,
      );
      await _cameraController!.initialize();
      if (mounted) setState(() => _isCameraReady = true);
    } catch (e) {
      if (mounted) setState(() => _permissionDenied = true);
    }
  }

  Future<void> _startRecording() async {
    if (kIsWeb) {
      await _pickAndUploadWebVideo();
      return;
    }

    final hasPermission = await _ensureCameraPermission();
    if (!hasPermission || !_isCameraReady) return;
    setState(() {
      _isRecording = true;
      _countdown = 20;
    });
    if (!kIsWeb) {
      await _cameraController?.startVideoRecording();
    }
    _runCountdown();
  }

  void _runCountdown() {
    if (!mounted || _countdown <= 0) {
      _stopRecording();
      return;
    }
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted && _isRecording) {
        setState(() => _countdown--);
        _runCountdown();
      }
    });
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    setState(() => _isRecording = false);
    try {
      if (!kIsWeb && _cameraController != null) {
        final file = await _cameraController!.stopVideoRecording();
        _lastRecordedFilePath = file.path;
        await _runFaceCheck(file.path);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Video recording is not supported in the web preview. Please test on a real device.',
              ),
              backgroundColor: Color(0xFFFF4458),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 6),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) _showUploadError(e.toString());
    }
  }

  Future<void> _pickAndUploadWebVideo() async {
    try {
      final pickedVideo = await pickWebProfileVideoForModeration();
      if (pickedVideo == null) return;

      final bytes = Uint8List.fromList(pickedVideo.bytes);
      if (bytes.isEmpty) {
        throw Exception(
          'Recorded video is empty. Please record another video.',
        );
      }
      debugPrint(
        'PROFILE VIDEO WEB: capture accepted file=${pickedVideo.fileName} bytes=${bytes.length} frames=${pickedVideo.moderationFrames.length}',
      );
      await _uploadWebVideo(
        bytes,
        pickedVideo.fileName,
        pickedVideo.mimeType,
        pickedVideo.moderationFrames
            .map((frame) => Uint8List.fromList(frame))
            .toList(),
      );
    } catch (e) {
      if (mounted) _showUploadError(e.toString());
    }
  }

  Future<void> _uploadWebVideo(
    Uint8List bytes,
    String fileName,
    String mimeType,
    List<Uint8List> moderationFrames,
  ) async {
    setState(() {
      _isUploading = true;
      _uploadStatusTitle = 'Video captured. Checking your profile video...';
      _moderationStatus = 'pending';
    });
    try {
      final uid = SupabaseService.instance.currentUserId;
      if (uid == null) throw Exception('Not authenticated.');

      debugPrint('PROFILE VIDEO WEB: upload started from profile screen');
      final newVideoUrl = await SupabaseService.instance
          .uploadProfileVideoBytes(bytes, fileName, mimeType: mimeType)
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () => throw Exception(
              'Upload timed out after 60 seconds. Please check your connection.',
            ),
          );
      if (newVideoUrl == null || newVideoUrl.isEmpty) {
        throw Exception('Upload returned an empty URL. Please try again.');
      }
      debugPrint('PROFILE VIDEO WEB: upload succeeded from profile screen');

      await SupabaseService.instance.client
          .from('users')
          .update({
            'profile_video_url': newVideoUrl,
            'moderation_status': 'pending',
            'moderation_reason': 'New profile video uploaded from web.',
            'moderated_at': null,
          })
          .eq('id', uid);

      if (mounted) {
        setState(() => _uploadStatusTitle = 'Checking your video...');
      }

      if (moderationFrames.isNotEmpty) {
        final thumbnailUrl = await SupabaseService.instance
            .uploadProfileThumbnailBytes(moderationFrames.first);
        debugPrint(
          'THUMBNAIL WEB UPLOAD: profile screen saved yes/no=${thumbnailUrl?.isNotEmpty == true}',
        );
      }

      final frameUrls = <String>[];
      for (var i = 0; i < moderationFrames.length; i++) {
        final frameUrl = await SupabaseService.instance
            .uploadProfileModerationFrameBytes(moderationFrames[i], i);
        if (frameUrl != null && frameUrl.isNotEmpty) {
          frameUrls.add(frameUrl);
        }
      }
      debugPrint(
        'PROFILE VIDEO MODERATION: web captured/uploaded frames=${frameUrls.length}',
      );

      final moderation = await SupabaseService.instance.moderateProfileVideo(
        videoUrl: newVideoUrl,
        frameUrls: frameUrls,
      );
      final status =
          (moderation['moderation_status'] as String?) ?? 'needs_review';
      final reason = moderation['moderation_reason'] as String?;
      debugPrint(
        'PROFILE VIDEO MODERATION: web result status=$status reason=${reason ?? 'none'}',
      );

      if (status == 'rejected') {
        throw Exception(
          'This video could not be approved. Please upload a different profile video.',
        );
      }

      if (mounted) {
        setState(() {
          _isUploading = false;
          _recorded = true;
          _moderationStatus = status;
        });
        widget.onVideoUploaded?.call(newVideoUrl);
        if (status == 'needs_review') {
          debugPrint(
            'PROFILE VIDEO MODERATION: needs review — ${reason ?? 'no reason'}',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUploading = false);
        _showUploadError(e.toString());
      }
    }
  }

  /// Run face detection on 3 sampled frames from the recorded video.
  Future<void> _runFaceCheck(String filePath) async {
    setState(() => _isCheckingFace = true);

    // Show "Checking your video" overlay for at least 1.5 seconds
    final checkFuture = _detectFaceInVideo(filePath);
    await Future.wait([
      checkFuture,
      Future.delayed(const Duration(milliseconds: 1500)),
    ]);

    final faceDetected = await checkFuture;
    _faceDetectedInLastRecording = faceDetected;

    if (mounted) {
      setState(() => _isCheckingFace = false);
    }

    if (!faceDetected) {
      await _showNoFaceBottomSheet();
    } else {
      await _uploadVideo(filePath);
    }
  }

  Future<bool> _detectFaceInVideo(String filePath) async {
    if (kIsWeb) return true; // Skip on web
    try {
      return await detectFaceInVideoFile(filePath);
    } catch (e) {
      debugPrint('FACE DETECTION ERROR: $e');
      return true; // On error, allow upload
    }
  }

  Future<void> _showNoFaceBottomSheet() async {
    if (!mounted) return;
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _NoFaceBottomSheet(),
    );
    if (result == 'retry') {
      _retake();
    } else {
      // Continue anyway — upload without face verification
      if (_lastRecordedFilePath != null) {
        await _uploadVideo(_lastRecordedFilePath!);
      }
    }
  }

  Future<List<String>> _generateAndUploadModerationFrames(
    String videoFilePath,
  ) async {
    if (kIsWeb) return [];

    final frameUrls = <String>[];
    const frameTimesMs = [0, 7000, 14000];

    for (var i = 0; i < frameTimesMs.length; i++) {
      String? framePath;
      try {
        framePath = await vtp.VideoThumbnailPlus.thumbnailFile(
          video: videoFilePath,
          imageFormat: vtp.ImageFormat.JPEG,
          timeMs: frameTimesMs[i],
          quality: 82,
        );
        if (framePath == null || framePath.isEmpty) continue;

        final frameUrl = await SupabaseService.instance
            .uploadProfileModerationFrame(framePath, i);
        if (frameUrl != null && frameUrl.isNotEmpty) {
          frameUrls.add(frameUrl);
        }
      } catch (e) {
        debugPrint(
          'PROFILE VIDEO MODERATION: frame generation failed index=$i — $e',
        );
      } finally {
        if (framePath != null && framePath.isNotEmpty) {
          try {
            await File(framePath).delete();
          } catch (_) {}
        }
      }
    }

    debugPrint(
      'PROFILE VIDEO MODERATION: generated/uploaded frames=${frameUrls.length}',
    );
    return frameUrls;
  }

  Future<void> _uploadVideo(String filePath) async {
    setState(() {
      _isUploading = true;
      _uploadStatusTitle = 'Uploading your profile video...';
      _moderationStatus = 'pending';
    });
    try {
      final uid = SupabaseService.instance.currentUserId;
      if (uid == null) throw Exception('Not authenticated.');

      // Upload to storage
      await SupabaseService.instance
          .uploadProfileVideo(filePath)
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () => throw Exception(
              'Upload timed out after 60 seconds. Please check your connection.',
            ),
          );

      // Build the public URL with a cache-busting timestamp
      final timestampMs = DateTime.now().millisecondsSinceEpoch;
      final newVideoUrl =
          'https://vbaiivsvjdntzaffboue.supabase.co/storage/v1/object/public/profile-videos/$uid/profile.mp4?v=$timestampMs';

      // STEP 1 — update profile_video_url in users table
      debugPrint(
        'PROFILE VIDEO STEP 1: updating profile_video_url for user $uid',
      );
      final updateData = <String, dynamic>{
        'profile_video_url': newVideoUrl,
        'moderation_status': 'pending',
        'moderation_reason': 'New profile video uploaded.',
        'moderated_at': null,
      };

      // If face was detected, mark user as verified
      if (_faceDetectedInLastRecording) {
        updateData['is_verified'] = true;
        debugPrint('PROFILE VIDEO: face detected — setting is_verified=true');
      }

      await SupabaseService.instance.client
          .from('users')
          .update(updateData)
          .eq('id', uid);
      debugPrint('PROFILE VIDEO STEP 1 DONE');

      if (mounted) {
        setState(() => _uploadStatusTitle = 'Checking your video...');
      }

      final frameUrls = await _generateAndUploadModerationFrames(filePath);
      final moderation = await SupabaseService.instance.moderateProfileVideo(
        videoUrl: newVideoUrl,
        frameUrls: frameUrls,
      );
      final status =
          (moderation['moderation_status'] as String?) ?? 'needs_review';
      final reason = moderation['moderation_reason'] as String?;

      if (status == 'rejected') {
        throw Exception(
          'This video could not be approved. Please upload a different profile video.',
        );
      }

      // STEP 2 — confirm the save by querying back the value
      debugPrint(
        'PROFILE VIDEO STEP 2: querying back profile_video_url for user $uid',
      );
      final confirmResponse = await SupabaseService.instance.client
          .from('users')
          .select('profile_video_url, moderation_status')
          .eq('id', uid)
          .single();
      final savedUrl = confirmResponse['profile_video_url'] as String?;
      debugPrint(
        'PROFILE VIDEO STEP 2 DONE: saved profile_video_url matches=${savedUrl == newVideoUrl}, moderation_status=${confirmResponse['moderation_status']}',
      );
      if (savedUrl == newVideoUrl) {
        debugPrint(
          'PROFILE VIDEO STEP 2: ✅ profile_video_url confirmed saved correctly',
        );
      } else {
        debugPrint('PROFILE VIDEO STEP 2: ⚠️ profile_video_url mismatch');
      }

      // STEP 3 — call onVideoUploaded callback so profile screen refreshes
      debugPrint(
        'PROFILE VIDEO STEP 3: calling onVideoUploaded callback with $newVideoUrl',
      );
      if (mounted) {
        setState(() {
          _isUploading = false;
          _recorded = true;
          _moderationStatus = status;
        });
        widget.onVideoUploaded?.call(newVideoUrl);
        if (status == 'needs_review') {
          debugPrint(
            'PROFILE VIDEO MODERATION: needs review — ${reason ?? 'no reason'}',
          );
        } else {
          debugPrint('PROFILE VIDEO MODERATION: approved automatically');
        }
        debugPrint(
          'PROFILE VIDEO STEP 3 DONE: onVideoUploaded callback called',
        );
      }
    } catch (e) {
      debugPrint('PROFILE VIDEO ERROR: $e');
      if (mounted) {
        setState(() => _isUploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.toString().replaceFirst('Exception: ', ''),
              style: GoogleFonts.dmSans(color: Colors.white),
            ),
            backgroundColor: const Color(0xFFFF4458),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 10),
            action: _lastRecordedFilePath != null
                ? SnackBarAction(
                    label: 'Retry',
                    textColor: Colors.white,
                    onPressed: () {
                      if (_lastRecordedFilePath != null) {
                        _uploadVideo(_lastRecordedFilePath!);
                      }
                    },
                  )
                : null,
          ),
        );
      }
    }
  }

  void _showUploadError(String error) {
    final message = error.replaceFirst('Exception: ', '');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Upload failed: $message',
          style: GoogleFonts.dmSans(color: Colors.white),
        ),
        backgroundColor: const Color(0xFFFF4458),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 10),
        action: _lastRecordedFilePath != null
            ? SnackBarAction(
                label: 'Retry',
                textColor: Colors.white,
                onPressed: () {
                  if (_lastRecordedFilePath != null) {
                    _uploadVideo(_lastRecordedFilePath!);
                  }
                },
              )
            : null,
      ),
    );
  }

  void _retake() {
    setState(() {
      _recorded = false;
      _lastRecordedFilePath = null;
      _faceDetectedInLastRecording = false;
      _moderationStatus = 'pending';
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundDark,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          kIsWeb ? 'Record Profile Video' : 'Record Profile Video',
          style: GoogleFonts.dmSans(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kIsWeb
                      ? 'Record Your Video Profile'
                      : 'Record your profile video',
                  style: GoogleFonts.dmSans(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  kIsWeb
                      ? 'Record a fresh 20-second video so people know you are real.'
                      : 'A 20-second face-to-camera video. No filters. Just the real you.',
                  style: GoogleFonts.dmSans(
                    fontSize: 14,
                    color: AppTheme.textSecondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                if (kIsWeb && !_recorded && !_isUploading) ...[
                  _buildRecordingControls(),
                  const SizedBox(height: 14),
                ],
                if (_isUploading) ...[
                  _buildModerationStatusCard(),
                  const SizedBox(height: 14),
                ],
                if (_recorded) ...[
                  _buildModerationStatusCard(),
                  const SizedBox(height: 14),
                ],
                if (!_isRecording && !_recorded) _buildPromptCard(),
                if (!_isRecording && !_recorded) ...[
                  const SizedBox(height: 12),
                  _buildTipsBar(),
                  const SizedBox(height: 12),
                ],
                if (_isRecording || _recorded) const SizedBox(height: 16),
                AspectRatio(
                  aspectRatio: 3 / 4,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: _buildCameraArea(),
                  ),
                ),
                const SizedBox(height: 20),
                if (!kIsWeb && !_recorded && !_isUploading && !_isCheckingFace)
                  _buildRecordingControls(),
                if (_recorded && !kIsWeb) _buildRecordedState(),
                const SizedBox(height: 24),
              ],
            ),
          ),
          // "Checking your video" overlay
          if (_isCheckingFace)
            Positioned.fill(
              child: Container(
                color: Colors.black.withAlpha(204),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: CircularProgressIndicator(
                          color: const Color(0xFFE8503A),
                          strokeWidth: 3,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Checking your video',
                        style: GoogleFonts.outfit(
                          fontSize: 16,
                          color: const Color(0xFFF5F0E8),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Full-screen upload overlay
          if (_isUploading && !kIsWeb)
            Positioned.fill(
              child: Container(
                color: Colors.black.withAlpha(204),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.asset(
                          'assets/images/App_Logo_Icon-1776473863446.png',
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          color: Color(0xFFE8503A),
                          strokeWidth: 3,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _uploadStatusTitle,
                        style: GoogleFonts.outfit(
                          fontSize: 16,
                          color: const Color(0xFFF5F0E8),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This may take a moment. Do not close the app.',
                        style: GoogleFonts.dmSans(
                          fontSize: 13,
                          color: AppTheme.textMuted,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Frosted glass tips bar shown below prompt card and above camera preview
  Widget _buildTipsBar() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withAlpha(30), width: 1),
          ),
          child: Row(
            children: [
              // Coral face outline icon
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8503A).withAlpha(26),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.face_outlined,
                  color: Color(0xFFE8503A),
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Face the camera directly · Speak clearly · Good lighting helps',
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPromptCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(20),
        border: Border(
          left: const BorderSide(color: Color(0xFFE8503A), width: 3),
          top: BorderSide(color: Colors.white.withAlpha(26), width: 1),
          right: BorderSide(color: Colors.white.withAlpha(26), width: 1),
          bottom: BorderSide(color: Colors.white.withAlpha(26), width: 1),
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ANSWER THIS',
            style: GoogleFonts.outfit(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: const Color(0xFFE8503A),
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _currentPrompt,
            style: GoogleFonts.outfit(
              fontSize: 20,
              fontStyle: FontStyle.italic,
              color: Colors.white,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: _pickDifferentPrompt,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Different question',
              style: GoogleFonts.outfit(
                fontSize: 13,
                color: const Color(0xFFE8503A),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraArea() {
    if (_permissionDenied) {
      return Container(
        color: AppTheme.backgroundVariant,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.videocam_off_rounded,
                color: AppTheme.textMuted,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                'Camera access required',
                style: GoogleFonts.dmSans(
                  color: AppTheme.textSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _initCamera,
                child: Text(
                  'Allow Camera',
                  style: GoogleFonts.dmSans(color: AppTheme.primary),
                ),
              ),
              TextButton(
                onPressed: () async => await openAppSettings(),
                child: Text(
                  'Open Settings',
                  style: GoogleFonts.dmSans(color: AppTheme.primary),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isCameraReady) {
      return Container(
        color: AppTheme.backgroundVariant,
        child: const Center(
          child: CircularProgressIndicator(color: AppTheme.primary),
        ),
      );
    }

    if (_recorded) {
      return Container(
        color: AppTheme.backgroundVariant,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0x334CAF82),
                  borderRadius: BorderRadius.circular(36),
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: AppTheme.sparkGreen,
                  size: 40,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _moderationStatus == 'approved'
                    ? 'Video approved!'
                    : 'Video saved for review',
                style: GoogleFonts.dmSans(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (kIsWeb) {
      return Container(
        color: AppTheme.backgroundVariant,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withAlpha(36),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: AppTheme.primary.withAlpha(92),
                      width: 1,
                    ),
                  ),
                  child: const Icon(
                    Icons.upload_file_rounded,
                    color: AppTheme.primary,
                    size: 38,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Record Your Video Profile',
                  style: GoogleFonts.dmSans(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Use your camera to record now. Keep it 20 seconds or shorter.',
                  style: GoogleFonts.dmSans(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    height: 1.45,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (!kIsWeb && _cameraController != null)
          CameraPreview(_cameraController!)
        else
          Container(
            color: AppTheme.backgroundVariant,
            child: Center(
              child: Icon(
                Icons.videocam_rounded,
                color: AppTheme.textMuted.withAlpha(128),
                size: 64,
              ),
            ),
          ),
        // Coral oval face guide — only shown before recording starts
        if (!_isRecording)
          Center(
            child: IgnorePointer(
              child: CustomPaint(
                size: const Size(double.infinity, double.infinity),
                painter: _FaceOvalPainter(),
              ),
            ),
          ),
        if (_isRecording)
          Positioned(
            top: 16,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(166),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: const Color(0xFFE8503A).withAlpha(153),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ScaleTransition(
                    scale: _pulseAnim,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: AppTheme.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _pillText(_currentPrompt),
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_countdown}s',
                    style: GoogleFonts.dmSans(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRecordingControls() {
    if (kIsWeb) {
      return SizedBox(
        width: double.infinity,
        height: 54,
        child: ElevatedButton.icon(
          onPressed: () {
            debugPrint('WEB VIDEO: profile video record CTA tapped');
            _pickAndUploadWebVideo();
          },
          icon: const Icon(Icons.upload_file_rounded),
          label: const Text('Record 20-Second Video'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
            textStyle: GoogleFonts.dmSans(
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    return Center(
      child: GestureDetector(
        onTap: _isRecording ? _stopRecording : _startRecording,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: _isRecording
                ? const Color(0x33FF4458)
                : const Color(0x33FFFFFF),
            borderRadius: BorderRadius.circular(36),
            border: Border.all(
              color: _isRecording
                  ? AppTheme.primary
                  : AppTheme.borderGlassActive,
              width: 2,
            ),
          ),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: _isRecording ? 24 : 48,
              height: _isRecording ? 24 : 48,
              decoration: BoxDecoration(
                color: AppTheme.primary,
                borderRadius: BorderRadius.circular(_isRecording ? 6 : 24),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecordedState() {
    return Center(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0x334CAF82),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0x664CAF82), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: AppTheme.sparkGreen,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  _moderationStatus == 'approved'
                      ? 'Video approved'
                      : 'Video saved for review',
                  style: GoogleFonts.dmSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.sparkGreen,
                  ),
                ),
              ],
            ),
          ),
          if (_moderationStatus == 'needs_review') ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Your profile video will appear in Discover after review.',
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(
                  fontSize: 12,
                  color: AppTheme.textMuted,
                  height: 1.4,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextButton(
            onPressed: _retake,
            child: Text(
              'Retake video',
              style: GoogleFonts.dmSans(
                fontSize: 14,
                color: AppTheme.textSecondary,
                decoration: TextDecoration.underline,
                decorationColor: AppTheme.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            ),
            child: Text(
              'Done',
              style: GoogleFonts.dmSans(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModerationStatusCard() {
    final isChecking = _isUploading || _moderationStatus == 'pending';
    final isApproved = _moderationStatus == 'approved';
    final isReview = _moderationStatus == 'needs_review';
    final title = isChecking
        ? 'Checking your video...'
        : isApproved
        ? 'Video approved'
        : isReview
        ? 'Video received'
        : 'Please record a new video';
    final body = isChecking
        ? 'We’re making sure your video follows FaceMeet safety standards. This usually takes a few seconds.'
        : isApproved
        ? 'Your profile video is ready.'
        : isReview
        ? 'Your video is being reviewed. You can continue setting up your profile while we finish checking it.'
        : 'This video could not be approved. Please record a fresh 20-second video.';
    final color = _moderationStatus == 'rejected'
        ? const Color(0xFFFF4458)
        : isApproved
        ? AppTheme.sparkGreen
        : AppTheme.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withAlpha(110), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isChecking)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                color: AppTheme.primary,
                strokeWidth: 2.5,
              ),
            )
          else
            Icon(
              isApproved
                  ? Icons.check_circle_rounded
                  : isReview
                  ? Icons.hourglass_top_rounded
                  : Icons.error_rounded,
              color: color,
              size: 22,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.dmSans(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: GoogleFonts.dmSans(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom painter for the coral oval face guide overlay
class _FaceOvalPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE8503A)
          .withAlpha(77) // 30% opacity
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    // Oval roughly the size a face occupies at normal selfie distance
    final ovalWidth = size.width * 0.55;
    final ovalHeight = size.height * 0.52;
    final centerX = size.width / 2;
    final centerY = size.height * 0.44;

    final rect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: ovalWidth,
      height: ovalHeight,
    );

    canvas.drawOval(rect, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Bottom sheet shown when no face is detected in the recorded video
class _NoFaceBottomSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: Colors.white.withAlpha(20), width: 1),
      ),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(51),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          // Coral face icon
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFFE8503A).withAlpha(26),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.face_outlined,
              color: Color(0xFFE8503A),
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            "Hmm, we couldn't see your face clearly",
            style: GoogleFonts.outfit(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.3,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Make sure your face is well lit and centered in the frame',
            style: GoogleFonts.dmSans(
              fontSize: 14,
              color: const Color(0xFF8A8A9A),
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          // Try Again button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context, 'retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE8503A),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(
                'Try Again',
                style: GoogleFonts.dmSans(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Continue Anyway button
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.pop(context, 'continue'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(
                'Continue Anyway',
                style: GoogleFonts.dmSans(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF8A8A9A),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

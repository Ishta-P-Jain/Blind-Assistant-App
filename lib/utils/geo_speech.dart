import 'package:speech_to_text/speech_to_text.dart' as stt;

class GeoSpeech {
  static final stt.SpeechToText _speech = stt.SpeechToText();
  static bool _isListening = false;
  static Function(String)? _callback;

  /// Starts continuous listening
  static Future<void> startListening(Function(String) onCommand) async {
    _callback = onCommand;

    bool available = await _speech.initialize(
      onError: (err) {
        _isListening = false;
        restart(); // auto restart on error
      },
      onStatus: (status) {
        if (status == "notListening") {
          _isListening = false;
          restart();
        }
      },
    );

    if (!available) {
      print("Speech recognition unavailable.");
      return;
    }

    _listen();
  }

  /// Internal function to start listening
  static void _listen() {
    if (_isListening) return; // already listening

    _isListening = true;

    _speech.listen(
      listenFor: const Duration(hours: 1),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      onResult: (result) {
        final command = result.recognizedWords.toLowerCase().trim();

        if (command.isNotEmpty && _callback != null) {
          _callback!(command); // Send recognized words to main.dart
        }
      },
    );
  }

  /// Automatically restart if listening stops unexpectedly
  static void restart() async {
    if (!_isListening) {
      await Future.delayed(const Duration(milliseconds: 300));
      _listen();
    }
  }

  /// Manually stop listening
  static void stop() {
    _speech.stop();
    _isListening = false;
  }
}

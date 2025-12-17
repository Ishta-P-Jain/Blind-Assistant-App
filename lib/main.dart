import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'utils/geo_speech.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(BlindAssistApp(cameras: cameras));
}


class BlindAssistApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const BlindAssistApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Blind Assist",
      debugShowCheckedModeBanner: false,
      home: HomePage(cameras: cameras),
    );
  }
}

class HomePage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const HomePage({super.key, required this.cameras});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late CameraController cameraController;
  Interpreter? interpreter;
  late FlutterTts tts;

  bool isDetecting = false;
  bool speakOnce = true;

  final int inputSize = 320;
  late List<String> labels;

  @override
  void initState() {
    super.initState();
    initCamera();
    initInterpreter();
    loadLabels();
    tts = FlutterTts();
    GeoSpeech.startListening(onCommandDetected);
  }

  void onCommandDetected(String command) {
    if (command.toLowerCase().contains("detect")) {
      speak("Detection enabled");
      speakOnce = true;
    }
  }

  void speak(String text) {
    tts.speak(text);
  }

  // ---------------------- LABEL LOADING ---------------------- (front view) //
  Future<void> loadLabels() async {
    final raw = await rootBundle.loadString("assets/models/labels.txt");
    labels = raw.split('\n');
  }

  // ---------------------- TFLITE SETUP ----------------------- //
  Future<void> initInterpreter() async {
    interpreter = await Interpreter.fromAsset(
      'models/blind_assist_model.tflite',
      options: InterpreterOptions()..threads = 2,
    );
    print("TFLite interpreter loaded!");
  }

  // ---------------------- CAMERA SETUP ----------------------- //
  Future<void> initCamera() async {
    cameraController = CameraController(
      widget.cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await cameraController.initialize();
    cameraController.startImageStream(processCameraImage);
    if (mounted) setState(() {});
  }

  // ---------------------- SSD OUTPUT PARSING ----------------------- //

  List<Map<String, dynamic>> parseDetections(
      List boxes, List classes, List scores) {
    List<Map<String, dynamic>> results = [];

    for (int i = 0; i < 10; i++) {
      double score = scores[0][i];
      if (score > 0.5) {
        int classIndex = classes[0][i].toInt();
        results.add({
          "label": labels[classIndex],
          "score": score,
          "box": boxes[0][i], // [ymin, xmin, ymax, xmax]
        });
      }
    }

    return results;
  }

  // ---------------------- DIRECTION + DISTANCE LOGIC ----------------------- //

  String getDirection(double xmin, double xmax) {
    double centerX = (xmin + xmax) / 2;

    if (centerX < 0.33) return "left";
    if (centerX < 0.66) return "center";
    return "right";
  }

  String getDistance(double ymin, double ymax) {
    double height = ymax - ymin;

    if (height > 0.6) return "very close";
    if (height > 0.35) return "near";
    return "far";
  }

  // ---------------------- CAMERA PROCESSOR ----------------------- //

  void processCameraImage(CameraImage image) async {
    if (interpreter == null || isDetecting) return;

    isDetecting = true;

    try {
      final rgbImage = convertYUV420toImage(image);

      final resized = img.copyResize(rgbImage,
          width: inputSize, height: inputSize);

      final inputTensor = imageToByteListUint8(resized, inputSize);

      var boxes = List.filled(1 * 10 * 4, 0.0).reshape([1, 10, 4]);
      var classes = List.filled(1 * 10, 0.0).reshape([1, 10]);
      var scores = List.filled(1 * 10, 0.0).reshape([1, 10]);

      interpreter!.runForMultipleInputs(
        [inputTensor],
        {
          0: boxes,
          1: classes,
          2: scores,
        },
      );

      final detections = parseDetections(boxes, classes, scores);

      if (detections.isNotEmpty && speakOnce) {
        speakOnce = false;

        final det = detections.first;
        final label = det["label"];
        final box = det["box"];

        final direction = getDirection(box[1], box[3]); // xmin,xmax
        final distance = getDistance(box[0], box[2]);   // ymin,ymax

        speak("$label on your $direction, $distance");

        Future.delayed(const Duration(seconds: 2), () {
          speakOnce = true;
        });
      }
    } catch (e) {
      print("Detection error: $e");
    }

    isDetecting = false;
  }

  // ---------------------- IMAGE CONVERSION ----------------------- //

  Uint8List imageToByteListUint8(img.Image image, int inputSize) {
    var convertedBytes = Uint8List(inputSize * inputSize * 3);
    int index = 0;

    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final pixel = image.getPixel(x, y);

        convertedBytes[index++] = img.getRed(pixel);
        convertedBytes[index++] = img.getGreen(pixel);
        convertedBytes[index++] = img.getBlue(pixel);
      }
    }

    return convertedBytes;
  }

  img.Image convertYUV420toImage(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final img.Image rgbImage = img.Image(width: width, height: height);

    final plane = image.planes;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yp = plane[0].bytes[y * plane[0].bytesPerRow + x];

        final uvIdx =
            (y ~/ 2) * plane[1].bytesPerRow + (x ~/ 2) * 2;

        final up = plane[1].bytes[uvIdx];
        final vp = plane[2].bytes[uvIdx];

        int r = (yp + vp * 1436 ~/ 1024 - 179).clamp(0, 255);
        int g = (yp -
                up * 46549 ~/ 131072 +
                44 -
                vp * 93604 ~/ 131072 +
                91)
            .clamp(0, 255);
        int b =
            (yp + up * 1814 ~/ 1024 - 227).clamp(0, 255);

        rgbImage.setPixelRgba(x, y, r, g, b, 255);
      }
    }

    return rgbImage;
  }

  // ---------------------- CLEANUP ----------------------- //
  @override
  void dispose() {
    cameraController.dispose();
    interpreter?.close();
    super.dispose();
  }

  // ---------------------- UI ----------------------- //
  @override
  Widget build(BuildContext context) {
    if (!cameraController.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          CameraPreview(cameraController),
          Positioned(
            bottom: 40,
            left: 20,
            child: Text(
              "Blind Assist - Detection Active",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
              ),
            ),
          )
        ],
      ),
    );
  }
}

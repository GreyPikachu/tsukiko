/// Какой нативный рантайм понимает файл модели.
///
/// Определение по формату, а не по настройке рядом: модель можно выбрать
/// из общей папки, перенести с другого компьютера или указать вручную.
enum RecognitionEngine { whisperCpp, nemoSpeechCpp }

RecognitionEngine engineForModel(String path) =>
    path.toLowerCase().endsWith('.gguf')
    ? RecognitionEngine.nemoSpeechCpp
    : RecognitionEngine.whisperCpp;

String engineTechnicalName(RecognitionEngine engine) => switch (engine) {
  RecognitionEngine.whisperCpp => 'whisper.cpp',
  RecognitionEngine.nemoSpeechCpp => 'NeMo-Speech.cpp',
};

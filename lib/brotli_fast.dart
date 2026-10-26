/// Fast, pure Dart Brotli (RFC 7932) encoder and decoder.
///
/// ```dart
/// import 'package:brotli_fast/brotli_fast.dart';
///
/// final packed = brotliEncode(bytes);              // quality 5
/// final smallest = brotliEncode(bytes, quality: 11);
/// final restored = brotliDecode(packed);
///
/// // As a dart:convert codec, also for streams:
/// await file.openRead().transform(brotli.decoder).pipe(sink);
/// ```
///
/// Works on the VM, AOT, Flutter and the web (JS and WebAssembly), with no
/// native dependencies.
library;

export 'src/brotli.dart'
    show
        brotliDecode,
        brotliDefaultMaxOutputSize,
        brotliDefaultQuality,
        brotliDefaultWindowBits,
        brotliEncode;
export 'src/codec.dart' show BrotliCodec, BrotliDecoder, BrotliEncoder, brotli;
export 'src/common/errors.dart' show BrotliErrorCode, BrotliException;
export 'src/dictionary.dart' show BrotliDictionary, maxDictionarySize;

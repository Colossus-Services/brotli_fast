/// Streams produced by the reference encoder (google/brotli), inlined as base64
/// so this test also runs in the browser.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:test/test.dart';

import '../benchmark/corpus.dart';

final class _Vector {
  _Vector(this.name, this.base64Stream, this.raw);

  final String name;
  final String base64Stream;
  final Uint8List raw;

  Uint8List get stream => base64.decode(base64Stream);
}

final List<_Vector> _vectors = <_Vector>[
  // Window 16 + `11` empty last meta-block.
  _Vector('empty', 'Bg==', Uint8List(0)),
  _Vector('x', 'CwCAWAM=', Uint8List.fromList(<int>[0x58])),
  _Vector(
    'quickfox',
    'CxWAVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZwM=',
    Uint8List.fromList(
      utf8.encode('The quick brown fox jumps over the lazy dog'),
    ),
  ),
  _Vector(
    '10x10y',
    'GxMAAKSwsuqBRwKK',
    Uint8List.fromList(<int>[
      ...List.filled(10, 0x58),
      ...List.filled(10, 0x59),
    ]),
  ),
  // Dictionary-heavy.
  _Vector('xyzzy', 'CwKAWHl6enkD', Uint8List.fromList(utf8.encode('Xyzzy'))),
  // `brotli -q 11` of makeText(20000): context modeling, block splits.
  _Vector(
    'text q11',
    'Hx9OCBwHbqzYrukpfQhqc6maq8qDwlA4LCNQR5OO9Pptc5ZgFKHA89/f89NjAfqb86qJE0rsn9'
        '/MFQkCTCRQv7i2vUfBVNhTuWE2QWwkHR1sEQcX/S/Ye20/576vvP3zWf808fXVZL333/'
        'btcf6N7Ndf7M3ofBSef+nywfPjp/EZPT/m8UA5PgfHnevc8vWu8/nT2/qp0xv0SWWa2mi/'
        'XlY5z25yvV5VNQ/us2OfVz0Pb3LFXlUzTqzfrpfUToMbbdbL6jxOLD96Qd2Hmd2u1Ovqz'
        'XOLL9afvvcwzGz10ueVJ4Prd+s1lfOxy/X6tKpvHOuPXlX9bGz95fqkmnlwk6NX1T68vn'
        '6vXlBnGttrqz6x7ji1eLc+o972X9x2SkjbS0h8glNAQlNEUlNAJVd8pVd0pVdmFVGhVUJ'
        'ldwEd3yV0fAd3AR3aRXRqFzDJEz/pEz3pkzlFTOiUMNlbwMZvCRu/wVvAhm4Rm7oFnOQT'
        'f9JP9Ek/maeIE3pKONm3gBt/S7jxN/gWcENvETf1FvCSX/xLf9Ev/WW+Il7oK+F1beEGwu'
        'WFOwiXFy4s3EC4qHAL4arCDWD7/ZoPj40OSgYsCeAk4BOBj0wCKhmwJEDjw2PDg5KBSgQ'
        '4CfhE4COTgEoGLAnQ+PDY8KBkoBIBTgI+EfjIJKCSAUsCND48NjwoGahEgJOATwQ+MgmoZ'
        'MCSAI0Pjw0PSgYqEbwk',
    makeText(20000),
  ),
  // `brotli -q 5` of makeBinary(6000).
  _Vector(
    'binary q5',
    'H28XAGQAbgrANUENMk6I9BSgA6rRJc1Eues5fiYKI5rbc8mQmcpYYGAV57tpxoAevK53oh'
        'XiIJY+pFcyiPjNO9mF1NdCrgtmf4J1v/siMVgsSRA8CMkxQgBgou8BxrpABMevk0noyE3'
        '3yIMTO7c2qMOZWc1byj0Pk2SJDTU222ZAyudw+1z78C9DieqeyaCqnrOmIxQkj7ODe5eX'
        'J6q2p6+iK9qyNtFRy7+k0P9+4lSXLDQWj9S/oOuQzf61tCuq9CWbLdxzi2DEGyK1pEW8c'
        '31JKOx2OPiil9w2dzzqKsAEAv/ZX07P3ch6FpstHS4lwPmw9VxvYItnBbws/o+cUsP+1u'
        'q9Of8d4iTiuYIQzJ1+8DufagXyZN6qdxBcoHvPDGjy2wX8Dn6COQfA41CyCSvoWrgGIeJ'
        'Rc4gq6Vu5gyET0HKJqwBtPCFQieh5JNUM7byh0EkY+aQ1jB18YTDJmAVktUyd/OGwKViF'
        '5HXMXQIRcKnYRRT1LN2CkfBpOMWUAdYe4CiEdNwSqga2XpBoxAy8UupG9j7QGKRM/DKa'
        'Jo5+sFjkLIJy2mbOAfA4lGw9AFH3afB0QLrs6x0AKCW+9jOAlmnuBRiZCLAmpwxxg7zbR'
        'NaZfywcojhJvTbl9HlzXtAE82NZ6EkblyBjl1M3YzoiNHPgAxbNuGgZTJHksHpHBMxIg6'
        'Ed0XApfs8hB9wf2BuP0AxnXuogvxwKHAIGNViBViaYyUFtsPMcbJgojdSVFHqLrLjLZf4'
        'WNdYrO+cvS7JsPZCP5xTydd0xV4ey6LbE0szCuSG3qFrZEGdggSVvnQ3vKgaM3sxrIr+x'
        'zp78Gq7E8sz5mCBHAOamMTejfOni6faOz3GxdQcBRxjcBzy2+GAu+HDIU7EoI4fCtTfJN'
        'SH5nltjglz9JgxxgDtF0gwFUehNKiCSKazDsjeQMYQRMRgOrCKZCPAyERBkIiBKs+u3gC'
        'TT3AvIMhFQTM4O+sFTUe/jv745iQsSA1ZbM0apar3oIWFyI87wMbrvW6kTyKXGi6ujuPI'
        'yfIMUGWdOJpc0iJAR5AF4OY7WNG/1ii03p0bpgOzOBQxqOi6QNNzQQAEeQRab79Bj6rcm'
        'bkKrZtHZ+KjFP11pugaIjxFNHgY8+E0gZ+Q32xL0Rfh7lYFN7O3EPZk+r5ro2VcYMFojr'
        'YcUnTFD12We1tLPz23IcXzJIavmOl3V9igP/EZFZ1I6k/z9zSsARATLHmDosd1IUpEqmy'
        '6GqmcukcMnkPCA7XEGnU93kgzcXjn97fdVF5S9+RHRTqYfE+zaARwS/Tz8kPG0+WEzKlh'
        'FMhHQZCKgy0TAkGbXbwFTprkXsGQiYJsckQyETGW3pK8Vc+349B0wroU8OElx+I05hawV'
        'kKMFaVQub6Z5VcJqgKeBV9n1V5aMHFXpl07OzBHo+fjFEMowGiO0tI69SkeB+nZBHCTPg'
        '0zpFKm0EUv3Bf5oanRrB7octNoDAUfVf104Hi/ATw0goHRJDxTHVzAZZChvEQRjsP1zpS'
        'YUvu6matayCyNw8V4SMCsGJWXu8T0A+jLH+QtIGPGzy5qxKEKOcMKy0wR/Yf2/bN73KzF'
        'ZRe0aXxlJG7Qp3FLUiRWim5hmkpCVJztM6ehL+CVQvtCCSxU8chWOPNlIoetYoWfWMIE8'
        'PIWNN/CvHaCCU5nVm4QDVpFMBFyvAA==',
    makeBinary(6000),
  ),
];

Future<Uint8List> _streamDecode(Uint8List stream, int chunk) async {
  final builder = BytesBuilder(copy: false);
  final chunks = Stream<List<int>>.fromIterable(<List<int>>[
    for (var i = 0; i < stream.length; i += chunk)
      stream.sublist(i, i + chunk < stream.length ? i + chunk : stream.length),
  ]);
  await for (final out in chunks.transform(brotli.decoder)) {
    builder.add(out);
  }
  return builder.takeBytes();
}

void main() {
  for (final vector in _vectors) {
    test('${vector.name}: one-shot', () {
      expect(brotliDecode(vector.stream), orderedEquals(vector.raw));
    });

    test('${vector.name}: streamed one byte at a time', () async {
      expect(await _streamDecode(vector.stream, 1), orderedEquals(vector.raw));
    });
  }
}

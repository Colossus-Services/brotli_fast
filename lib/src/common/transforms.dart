/// RFC 7932 dictionary word transforms.
///
/// The tables are unpacked from the same compact strings as the reference
/// implementation. Only RFC transforms are preloaded; the SHIFT operators are
/// implemented for future shared/compound dictionary support.
library;

import 'dart:typed_data';

/// Maximum transformed word length: prefix (5) + word (24) + suffix (8).
const int maxTransformedWordLength = 37;

const int _numRfcTransforms = 121;
const int _prefixSuffixLength = 167;
const int _prefixSuffixCount = 50;
const int _omitFirstLastLimit = 9;
const int _identity = 0;
const int _omitLastBase = _identity + 1 - 1;
const int _uppercaseFirst = _omitLastBase + _omitFirstLastLimit + 1;
const int _uppercaseAll = _uppercaseFirst + 1;
const int _omitFirstBase = _uppercaseAll + 1 - 1;
const int _shiftFirst = _omitFirstBase + _omitFirstLastLimit + 1;
const int _shiftAll = _shiftFirst + 1;

// Same source strings as the reference Java/JS decoder. `#` separates
// prefix/suffix entries; transform descriptors are chars offset by 32.
const String _prefixSuffixSrc =
    "# #s #, #e #.# the #.com/#\u00C2\u00A0# of # and"
    " # in # to #\"#\">#\n#]# for # a # that #. # with #'# from # by #. The # on # as # is #ing"
    " #\n\t#:#ed #(# at #ly #=\"# of the #. This #,# not #er #al #='#ful #ive #less #est #ize #"
    "ous #";

const String _transformsSrc =
    "     !! ! ,  *!  &!  \" !  ) *   * -  ! # !  #!*!  "
    "+  ,\$ !  -  %  .  / #   0  1 .  \"   2  3!*   4%  ! # /   5  6  7  8 0  1 &   \$   9 +   : "
    " ;  < '  !=  >  ?! 4  @ 4  2  &   A *# (   B  C& ) %  ) !*# *-% A +! *.  D! %'  & E *6  F "
    " G% ! *A *%  H! D  I!+!  J!+   K +- *4! A  L!*4  M  N +6  O!*% +.! K *G  P +%(  ! G *D +D "
    " Q +# *K!*G!+D!+# +G +A +4!+% +K!+4!*D!+K!*K";

/// A set of dictionary transforms.
final class Transforms {
  Transforms._(
    this.numTransforms,
    this.triplets,
    this.prefixSuffixStorage,
    this.prefixSuffixHeads,
    this.params,
  );

  final int numTransforms;
  final Int32List triplets;
  final Uint8List prefixSuffixStorage;
  final Int32List prefixSuffixHeads;
  final Int16List params;

  /// RFC 7932's 121 transforms.
  static final Transforms rfc = _unpackRfcTransforms();
}

Transforms _unpackRfcTransforms() {
  final storage = Uint8List(_prefixSuffixLength);
  final heads = Int32List(_prefixSuffixCount + 1);
  final triplets = Int32List(_numRfcTransforms * 3);
  final params = Int16List(_numRfcTransforms);

  var index = 1;
  var j = 0;
  for (var i = 0; i < _prefixSuffixSrc.length; i++) {
    final c = _prefixSuffixSrc.codeUnitAt(i);
    if (c == 0x23) {
      heads[index++] = j;
    } else {
      storage[j++] = c & 0xFF;
    }
  }
  if (index != _prefixSuffixCount + 1 || j != _prefixSuffixLength) {
    throw StateError(
      'RFC transform prefix/suffix table is malformed: '
      'heads=$index storage=$j',
    );
  }

  if (_transformsSrc.length != _numRfcTransforms * 3) {
    throw StateError(
      'RFC transform descriptor table is malformed: '
      '${_transformsSrc.length} != ${_numRfcTransforms * 3}',
    );
  }
  for (var i = 0; i < triplets.length; i++) {
    triplets[i] = _transformsSrc.codeUnitAt(i) - 32;
  }

  return Transforms._(_numRfcTransforms, triplets, storage, heads, params);
}

/// Applies transform [transformIndex] to a dictionary word.
///
/// Returns the number of bytes written into [dst] starting at [dstOffset].
/// The caller must provide at least [maxTransformedWordLength] bytes of space.
int transformDictionaryWord(
  Uint8List dst,
  int dstOffset,
  Uint8List src,
  int srcOffset,
  int wordLen,
  int transformIndex, {
  Transforms? transforms,
}) {
  final t = transforms ?? Transforms.rfc;
  final triplets = t.triplets;
  final storage = t.prefixSuffixStorage;
  final heads = t.prefixSuffixHeads;
  final base = transformIndex * 3;
  final prefixIdx = triplets[base];
  final transformType = triplets[base + 1];
  final suffixIdx = triplets[base + 2];

  var prefix = heads[prefixIdx];
  final prefixEnd = heads[prefixIdx + 1];
  var suffix = heads[suffixIdx];
  final suffixEnd = heads[suffixIdx + 1];

  var omitFirst = transformType - _omitFirstBase;
  var omitLast = transformType - _omitLastBase;
  if (omitFirst < 1 || omitFirst > _omitFirstLastLimit) omitFirst = 0;
  if (omitLast < 1 || omitLast > _omitFirstLastLimit) omitLast = 0;

  var offset = dstOffset;
  while (prefix != prefixEnd) {
    dst[offset++] = storage[prefix++];
  }

  var len = wordLen;
  if (omitFirst > len) omitFirst = len;
  var dictOffset = srcOffset + omitFirst;
  len -= omitFirst;
  len -= omitLast;
  var remaining = len;
  while (remaining > 0) {
    dst[offset++] = src[dictOffset++];
    remaining--;
  }

  if (transformType == _uppercaseFirst || transformType == _uppercaseAll) {
    var uppercaseOffset = offset - len;
    if (transformType == _uppercaseFirst) len = 1;
    while (len > 0) {
      final c0 = dst[uppercaseOffset] & 0xFF;
      if (c0 < 0xC0) {
        if (c0 >= 97 && c0 <= 122) {
          dst[uppercaseOffset] = dst[uppercaseOffset] ^ 32;
        }
        uppercaseOffset += 1;
        len -= 1;
      } else if (c0 < 0xE0) {
        dst[uppercaseOffset + 1] = dst[uppercaseOffset + 1] ^ 32;
        uppercaseOffset += 2;
        len -= 2;
      } else {
        dst[uppercaseOffset + 2] = dst[uppercaseOffset + 2] ^ 5;
        uppercaseOffset += 3;
        len -= 3;
      }
    }
  } else if (transformType == _shiftFirst || transformType == _shiftAll) {
    var shiftOffset = offset - len;
    final param = t.params[transformIndex];
    // Limited sign extension: scalar < (1 << 24).
    var scalar = (param & 0x7FFF) + (0x1000000 - (param & 0x8000));
    while (len > 0) {
      var step = 1;
      final c0 = dst[shiftOffset] & 0xFF;
      if (c0 < 0x80) {
        scalar += c0;
        dst[shiftOffset] = scalar & 0x7F;
      } else if (c0 < 0xC0) {
        // Continuation byte: leave it alone.
      } else if (c0 < 0xE0) {
        if (len >= 2) {
          final c1 = dst[shiftOffset + 1];
          scalar += (c1 & 0x3F) | ((c0 & 0x1F) << 6);
          dst[shiftOffset] = 0xC0 | ((scalar >> 6) & 0x1F);
          dst[shiftOffset + 1] = (c1 & 0xC0) | (scalar & 0x3F);
          step = 2;
        } else {
          step = len;
        }
      } else if (c0 < 0xF0) {
        if (len >= 3) {
          final c1 = dst[shiftOffset + 1];
          final c2 = dst[shiftOffset + 2];
          scalar += (c2 & 0x3F) | ((c1 & 0x3F) << 6) | ((c0 & 0x0F) << 12);
          dst[shiftOffset] = 0xE0 | ((scalar >> 12) & 0x0F);
          dst[shiftOffset + 1] = (c1 & 0xC0) | ((scalar >> 6) & 0x3F);
          dst[shiftOffset + 2] = (c2 & 0xC0) | (scalar & 0x3F);
          step = 3;
        } else {
          step = len;
        }
      } else if (c0 < 0xF8) {
        if (len >= 4) {
          final c1 = dst[shiftOffset + 1];
          final c2 = dst[shiftOffset + 2];
          final c3 = dst[shiftOffset + 3];
          scalar +=
              (c3 & 0x3F) |
              ((c2 & 0x3F) << 6) |
              ((c1 & 0x3F) << 12) |
              ((c0 & 0x07) << 18);
          dst[shiftOffset] = 0xF0 | ((scalar >> 18) & 0x07);
          dst[shiftOffset + 1] = (c1 & 0xC0) | ((scalar >> 12) & 0x3F);
          dst[shiftOffset + 2] = (c2 & 0xC0) | ((scalar >> 6) & 0x3F);
          dst[shiftOffset + 3] = (c3 & 0xC0) | (scalar & 0x3F);
          step = 4;
        } else {
          step = len;
        }
      }
      shiftOffset += step;
      len -= step;
      if (transformType == _shiftFirst) len = 0;
    }
  }

  while (suffix != suffixEnd) {
    dst[offset++] = storage[suffix++];
  }
  return offset - dstOffset;
}

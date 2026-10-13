import 'dart:convert';
import 'dart:typed_data';

import 'archive_io.dart';
import 'archive_row.dart';

/// Encodes up to about 256 rows of one channel into one compressed block.
///
/// Layout: a header (see `packPayload`), then zlib level 6 deflate of the row
/// count and one length-prefixed section per field. Presence bits make absent
/// fields free, repeated strings are dictionary coded, and timestamps are
/// zigzag deltas.
class ArchiveBlock {
  const ArchiveBlock._();

  static const int version = 1;

  /// Rows past this count are refused on decode as corrupt.
  static const int maxRows = 1 << 16;

  static const _bitMessageId = 1 << 0;
  static const _bitParent = 1 << 1;
  static const _bitRoot = 1 << 2;
  static const _bitReplyUser = 1 << 3;
  static const _bitMsgId = 1 << 4;
  static const _bitReward = 1 << 5;
  static const _bitBits = 1 << 6;
  static const _bitPaid = 1 << 7;
  static const _bitSourceBroadcaster = 1 << 8;
  static const _bitSourceMessage = 1 << 9;
  static const _bitEmotes = 1 << 10;
  static const _bitTags = 1 << 11;
  static const _knownBits = (1 << 12) - 1;

  static const _refLiteral = 0;
  static const _refSameAsParent = 1;
  static const _refRowBase = 2;

  static Uint8List encode(List<ArchiveRow> rows) {
    final ts = ByteWriter();
    final flags = ByteWriter();
    final presence = ByteWriter();
    final user = ByteWriter();
    final textLen = ByteWriter();
    final textBytes = ByteWriter();
    final ids = ByteWriter();
    final refs = ByteWriter();
    final bits = ByteWriter();
    final emoteCol = ByteWriter();
    final tagCol = ByteWriter();
    final tagVals = ByteWriter();
    final msgIds = _DictWriter();
    final replyUsers = _DictWriter();
    final rewards = _DictWriter();
    final paid = _DictWriter();
    final sourceBroadcasters = _DictWriter();
    final emoteIds = _DictWriter();
    final tagKeys = _DictWriter();

    final rowOfId = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      final id = rows[i].messageId;
      if (id != null) {
        rowOfId.putIfAbsent(id, () => i);
      }
    }

    var prevTs = 0;
    for (final r in rows) {
      ts.zigzag(r.timestampMs - prevTs);
      prevTs = r.timestampMs;
      flags.byte(
        (r.isSystem ? 1 : 0) |
            (r.isAction ? 2 : 0) |
            (r.isBanNotice ? 4 : 0) |
            (r.deleted ? 8 : 0) |
            (r.isFirstMessage ? 16 : 0) |
            (r.isBackfill ? 32 : 0) |
            (r.isHistory ? 64 : 0),
      );
      var p = 0;
      if (r.messageId != null) p |= _bitMessageId;
      if (r.replyParentId != null) p |= _bitParent;
      if (r.threadRootId != null) p |= _bitRoot;
      if (r.replyToUser != null) p |= _bitReplyUser;
      if (r.msgId != null) p |= _bitMsgId;
      if (r.customRewardId != null) p |= _bitReward;
      if (r.bitsAmount != null) p |= _bitBits;
      if (r.pinnedPaidAmount != null) p |= _bitPaid;
      if (r.sourceBroadcasterId != null) p |= _bitSourceBroadcaster;
      if (r.sourceMessageId != null) p |= _bitSourceMessage;
      if (r.emotes.isNotEmpty) p |= _bitEmotes;
      if (r.extraTags.isNotEmpty) p |= _bitTags;
      presence.varint(p);
      user.varint(r.user);
      final text = utf8.encode(r.text);
      textLen.varint(text.length);
      textBytes.bytes(text);

      final id = r.messageId;
      if (id != null) {
        _writeId(ids, id);
      }
      final parent = r.replyParentId;
      if (parent != null) {
        _writeRef(refs, ids, parent, rowOfId, null);
      }
      final root = r.threadRootId;
      if (root != null) {
        _writeRef(refs, ids, root, rowOfId, parent);
      }
      r.replyToUser.let(replyUsers.add);
      r.msgId.let(msgIds.add);
      r.customRewardId.let(rewards.add);
      final bitsAmount = r.bitsAmount;
      if (bitsAmount != null) {
        bits.varint(bitsAmount);
      }
      r.pinnedPaidAmount.let(paid.add);
      r.sourceBroadcasterId.let(sourceBroadcasters.add);
      final sourceId = r.sourceMessageId;
      if (sourceId != null) {
        _writeId(ids, sourceId);
      }
      if (r.emotes.isNotEmpty) {
        emoteCol.varint(r.emotes.length);
        var prevEnd = 0;
        for (final e in r.emotes) {
          emoteIds.add(e.id);
          emoteCol.zigzag(e.start - prevEnd);
          emoteCol.zigzag(e.end - e.start);
          prevEnd = e.end;
        }
      }
      if (r.extraTags.isNotEmpty) {
        tagCol.varint(r.extraTags.length);
        for (final (k, v) in r.extraTags) {
          tagKeys.add(k);
          tagVals.string(v);
        }
      }
    }

    final payload = ByteWriter()..varint(rows.length);
    for (final w in [
      ts,
      flags,
      presence,
      user,
      textLen,
      textBytes,
      ids,
      refs,
      bits,
      emoteCol,
      tagCol,
      tagVals,
    ]) {
      payload.section(w);
    }
    for (final d in [
      msgIds,
      replyUsers,
      rewards,
      paid,
      sourceBroadcasters,
      emoteIds,
      tagKeys,
    ]) {
      payload
        ..section(d.codes)
        ..section(d.strings);
    }
    return packPayload(version, payload.takeBytes());
  }

  /// Throws [ArchiveFormatException] on truncated, corrupt, or unknown data.
  static List<ArchiveRow> decode(Uint8List data) {
    final raw = unpackPayload(version, data, 'block');
    try {
      return _decodePayload(raw);
    } on ArchiveFormatException {
      rethrow;
    } on Object {
      throw const ArchiveFormatException('corrupt block contents');
    }
  }

  static List<ArchiveRow> _decodePayload(Uint8List raw) {
    final r = ByteReader(raw);
    final count = r.varint();
    if (count > maxRows) {
      throw const ArchiveFormatException('implausible row count');
    }
    final ts = r.section();
    final flags = r.section();
    final presence = r.section();
    final user = r.section();
    final textLen = r.section();
    final textBytes = r.section();
    final ids = r.section();
    final refs = r.section();
    final bits = r.section();
    final emoteCol = r.section();
    final tagCol = r.section();
    final tagVals = r.section();
    _DictReader dict() => _DictReader(r.section(), r.section());
    final msgIds = dict();
    final replyUsers = dict();
    final rewards = dict();
    final paid = dict();
    final sourceBroadcasters = dict();
    final emoteIds = dict();
    final tagKeys = dict();
    if (count > flags.remaining) {
      throw const ArchiveFormatException('implausible row count');
    }

    final parentCodes = List<int>.filled(count, -1);
    final rootCodes = List<int>.filled(count, -1);
    final parentLits = List<String?>.filled(count, null);
    final rootLits = List<String?>.filled(count, null);
    final messageIds = List<String?>.filled(count, null);
    final builders = <ArchiveRow Function(String?, String?)>[];

    var prevTs = 0;
    for (var i = 0; i < count; i++) {
      final stamp = prevTs += ts.zigzag();
      final f = flags.byte();
      final p = presence.varint();
      if (p & ~_knownBits != 0 || f & 0x80 != 0) {
        throw const ArchiveFormatException('unknown field bits');
      }
      final userRef = user.varint();
      final text = utf8.decode(textBytes.bytes(textLen.varint()));

      String? id;
      if (p & _bitMessageId != 0) {
        id = _readId(ids);
        messageIds[i] = id;
      }
      if (p & _bitParent != 0) {
        parentCodes[i] = refs.varint();
        if (parentCodes[i] == _refSameAsParent) {
          throw const ArchiveFormatException('parent cannot reference itself');
        }
        if (parentCodes[i] == _refLiteral) {
          parentLits[i] = _readId(ids);
        }
      }
      if (p & _bitRoot != 0) {
        rootCodes[i] = refs.varint();
        if (rootCodes[i] == _refSameAsParent && p & _bitParent == 0) {
          throw const ArchiveFormatException('root without parent');
        }
        if (rootCodes[i] == _refLiteral) {
          rootLits[i] = _readId(ids);
        }
      }
      final replyUser = p & _bitReplyUser != 0 ? replyUsers.read() : null;
      final msgId = p & _bitMsgId != 0 ? msgIds.read() : null;
      final reward = p & _bitReward != 0 ? rewards.read() : null;
      final bitsAmount = p & _bitBits != 0 ? bits.varint() : null;
      final paidAmount = p & _bitPaid != 0 ? paid.read() : null;
      final sourceBroadcaster = p & _bitSourceBroadcaster != 0
          ? sourceBroadcasters.read()
          : null;
      final sourceId = p & _bitSourceMessage != 0 ? _readId(ids) : null;

      var emotes = const <ArchiveEmote>[];
      if (p & _bitEmotes != 0) {
        final n = emoteCol.varint();
        if (n == 0 || n > emoteCol.remaining) {
          throw const ArchiveFormatException('bad emote count');
        }
        emotes = [];
        var prevEnd = 0;
        for (var e = 0; e < n; e++) {
          final eid = emoteIds.read();
          final start = prevEnd + emoteCol.zigzag();
          final end = start + emoteCol.zigzag();
          emotes.add(ArchiveEmote(eid, start, end));
          prevEnd = end;
        }
      }
      var tags = const <(String, String)>[];
      if (p & _bitTags != 0) {
        final n = tagCol.varint();
        if (n == 0 || n > tagVals.remaining) {
          throw const ArchiveFormatException('bad tag count');
        }
        tags = [];
        for (var t = 0; t < n; t++) {
          tags.add((tagKeys.read(), tagVals.string()));
        }
      }
      builders.add(
        (parent, root) => ArchiveRow(
          timestampMs: stamp,
          text: text,
          user: userRef,
          isSystem: f & 1 != 0,
          isAction: f & 2 != 0,
          isBanNotice: f & 4 != 0,
          deleted: f & 8 != 0,
          isFirstMessage: f & 16 != 0,
          isBackfill: f & 32 != 0,
          isHistory: f & 64 != 0,
          messageId: id,
          replyToUser: replyUser,
          msgId: msgId,
          customRewardId: reward,
          bitsAmount: bitsAmount,
          pinnedPaidAmount: paidAmount,
          sourceBroadcasterId: sourceBroadcaster,
          sourceMessageId: sourceId,
          emotes: emotes,
          extraTags: tags,
          replyParentId: parent,
          threadRootId: root,
        ),
      );
    }
    for (final s in [
      ts,
      flags,
      presence,
      user,
      textLen,
      textBytes,
      ids,
      refs,
      bits,
      emoteCol,
      tagCol,
      tagVals,
    ]) {
      if (s.remaining != 0) {
        throw const ArchiveFormatException('trailing data in column');
      }
    }
    if (r.remaining != 0) {
      throw const ArchiveFormatException('trailing data in block');
    }

    String resolve(int code, String? literal, String? parent) {
      if (code == _refLiteral) {
        return literal!;
      }
      if (code == _refSameAsParent) {
        return parent!;
      }
      final target = code - _refRowBase;
      final id = target < count ? messageIds[target] : null;
      if (id == null) {
        throw const ArchiveFormatException('reference to a row without an id');
      }
      return id;
    }

    // Reply references resolve after every message id is known.
    final rows = <ArchiveRow>[];
    for (var i = 0; i < count; i++) {
      final parent = parentCodes[i] < 0
          ? null
          : resolve(parentCodes[i], parentLits[i], null);
      final root = rootCodes[i] < 0
          ? null
          : resolve(rootCodes[i], rootLits[i], parent);
      rows.add(builders[i](parent, root));
    }
    return rows;
  }

  static void _writeRef(
    ByteWriter refs,
    ByteWriter ids,
    String id,
    Map<String, int> rowOfId,
    String? parent,
  ) {
    if (parent != null && id == parent) {
      refs.varint(_refSameAsParent);
      return;
    }
    final row = rowOfId[id];
    if (row != null) {
      refs.varint(_refRowBase + row);
      return;
    }
    refs.varint(_refLiteral);
    _writeId(ids, id);
  }

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  static void _writeId(ByteWriter w, String id) {
    if (!_uuid.hasMatch(id)) {
      w.byte(1);
      w.string(id);
      return;
    }
    w.byte(0);
    final hex = id.replaceAll('-', '');
    for (var i = 0; i < 32; i += 2) {
      w.byte(int.parse(hex.substring(i, i + 2), radix: 16));
    }
  }

  static const _hex = '0123456789abcdef';

  static String _readId(ByteReader r) {
    final kind = r.byte();
    if (kind == 1) {
      return r.string();
    }
    if (kind != 0) {
      throw const ArchiveFormatException('unknown id kind');
    }
    final b = r.bytes(16);
    final s = StringBuffer();
    for (var i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) {
        s.write('-');
      }
      s
        ..write(_hex[b[i] >> 4])
        ..write(_hex[b[i] & 15]);
    }
    return s.toString();
  }
}

/// Dictionary column: a code per use, and each string once in first-use order.
class _DictWriter {
  final Map<String, int> _ids = {};
  final ByteWriter codes = ByteWriter();
  final ByteWriter strings = ByteWriter();

  void add(String s) {
    var code = _ids[s];
    if (code == null) {
      code = _ids.length;
      _ids[s] = code;
      strings.string(s);
    }
    codes.varint(code);
  }
}

class _DictReader {
  _DictReader(this._codes, this._strings);

  final ByteReader _codes;
  final ByteReader _strings;
  final List<String> _list = [];

  String read() {
    final code = _codes.varint();
    if (code < _list.length) {
      return _list[code];
    }
    if (code != _list.length) {
      throw const ArchiveFormatException('bad dictionary code');
    }
    final s = _strings.string();
    _list.add(s);
    return s;
  }
}

extension _Let<T extends Object> on T? {
  void let(void Function(T) f) {
    final v = this;
    if (v != null) {
      f(v);
    }
  }
}

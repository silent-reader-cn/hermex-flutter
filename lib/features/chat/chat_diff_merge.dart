import '../../core/models/chat_message.dart';

/// 对比本地消息列表与服务端消息列表，执行 diff-merge（类 VDOM 调和）。
///
/// - 以 [serverMessages] 窗口为权威基准，匹配并原地更新 [localMessages] 中已有项；
/// - 补入服务端存在但本地缺失的消息；
/// - 保留本地历史分页消息（头部）及未落库乐观消息（尾部），不做删除；
/// - 兼容 `messageId == null` 或 `local-` 前缀的乐观消息指纹匹配。
List<ChatMessage> diffMergeMessages({
  required List<ChatMessage> localMessages,
  required List<ChatMessage> serverMessages,
}) {
  if (localMessages.isEmpty) {
    return _dedupeServerUserMessages(serverMessages);
  }
  if (serverMessages.isEmpty) {
    return List<ChatMessage>.of(localMessages);
  }

  serverMessages = _dedupeServerUserMessages(serverMessages);

  final matchedLocalIndices = <int>{};
  final serverToLocal = <int, int>{};

  for (var sIdx = 0; sIdx < serverMessages.length; sIdx++) {
    final sMsg = serverMessages[sIdx];
    for (var lIdx = 0; lIdx < localMessages.length; lIdx++) {
      if (matchedLocalIndices.contains(lIdx)) continue;
      if (isMessageMatch(localMessages[lIdx], sMsg)) {
        matchedLocalIndices.add(lIdx);
        serverToLocal[sIdx] = lIdx;
        break;
      }
    }
  }

  if (matchedLocalIndices.isEmpty) {
    // 双方无交集：比较时间戳确定前后关系
    final firstServerTs = serverMessages.first.timestamp;
    final lastLocalTs = localMessages.last.timestamp;
    if (firstServerTs != null &&
        lastLocalTs != null &&
        firstServerTs >= lastLocalTs) {
      return [...localMessages, ...serverMessages];
    }
    final lastServerTs = serverMessages.last.timestamp;
    final firstLocalTs = localMessages.first.timestamp;
    if (lastServerTs != null &&
        firstLocalTs != null &&
        lastServerTs <= firstLocalTs) {
      return [...serverMessages, ...localMessages];
    }
    final combined = [...localMessages, ...serverMessages];
    _stableSortMessages(combined);
    return combined;
  }

  final firstMatchedLocalIdx = matchedLocalIndices.reduce(
    (a, b) => a < b ? a : b,
  );
  final lastMatchedLocalIdx = matchedLocalIndices.reduce(
    (a, b) => a > b ? a : b,
  );

  final result = <ChatMessage>[];

  // 头部保留：早于首个命中项的本地历史消息（分页加载的更早记录）
  for (var i = 0; i < firstMatchedLocalIdx; i++) {
    result.add(localMessages[i]);
  }

  // 中部窗口：以服务端顺序为主，原地 patch 命中项，补入缺失项，并保留本地夹在中间未命中的项
  var currentLocalIdx = firstMatchedLocalIdx;

  for (var sIdx = 0; sIdx < serverMessages.length; sIdx++) {
    final sMsg = serverMessages[sIdx];
    final matchedLIdx = serverToLocal[sIdx];

    if (matchedLIdx != null) {
      while (currentLocalIdx < matchedLIdx) {
        if (!matchedLocalIndices.contains(currentLocalIdx)) {
          result.add(localMessages[currentLocalIdx]);
        }
        currentLocalIdx++;
      }
      final localOrig = localMessages[matchedLIdx];
      result.add(_patchMessage(localOrig, sMsg));
      if (matchedLIdx + 1 > currentLocalIdx) {
        currentLocalIdx = matchedLIdx + 1;
      }
    } else {
      result.add(sMsg);
    }
  }

  while (currentLocalIdx <= lastMatchedLocalIdx) {
    if (!matchedLocalIndices.contains(currentLocalIdx)) {
      result.add(localMessages[currentLocalIdx]);
    }
    currentLocalIdx++;
  }

  // 尾部保留：晚于最后一个命中项的本地未落库项（如发送中的乐观消息）
  for (var i = lastMatchedLocalIdx + 1; i < localMessages.length; i++) {
    if (!matchedLocalIndices.contains(i)) {
      result.add(localMessages[i]);
    }
  }

  return result;
}

/// 服务端 user 行自去重（真机双气泡 #67）：
///
/// webui 上游在同一回合可能落两条 user 行——一条解析版（带权威 id、
/// `[Workspace::v1]`/`[Attached files]`/`[screenshot]` 注入标记已剥离、
/// 带 attachments 字段），一条注入原文版（无 id、标记全保留），二者
/// timestamp 完全相同。客户端本地乐观消息只能匹配其中一条，另一条会被
/// 当「服务端缺失项」补入 → 用户消息双气泡（第二遍为未解析原文）。
///
/// 去重规则：相邻 user 行若 timestamp 相同（±0.5s 容差）且归一化内容
/// 相等，仅保留一条——优先保留带权威 id 的解析版。
List<ChatMessage> _dedupeServerUserMessages(List<ChatMessage> serverMessages) {
  bool hasAuthoritativeId(ChatMessage m) {
    final id = m.messageId;
    return id != null && id.isNotEmpty && !_isTempId(id);
  }

  final result = <ChatMessage>[];
  for (final msg in serverMessages) {
    if (msg.role == 'user' && result.isNotEmpty) {
      final prev = result.last;
      if (prev.role == 'user') {
        final prevTs = prev.timestamp;
        final curTs = msg.timestamp;
        final sameTs =
            prevTs != null &&
            curTs != null &&
            prevTs > 0 &&
            curTs > 0 &&
            (prevTs - curTs).abs() <= 0.5;
        if (sameTs) {
          final normPrev = _normalizeUserContent(prev.content ?? '');
          final normCur = _normalizeUserContent(msg.content ?? '');
          if (normPrev == normCur) {
            // 同一条消息的两个投影：保留带权威 id 的一条。
            if (hasAuthoritativeId(prev)) {
              continue; // 丢弃当前无权威 id 行
            }
            if (hasAuthoritativeId(msg)) {
              result[result.length - 1] = msg; // 替换为权威行
            }
            continue;
          }
        }
      }
    }
    result.add(msg);
  }
  return result;
}

/// 判断本地消息与服务端消息是否匹配。
bool isMessageMatch(ChatMessage local, ChatMessage server) {
  final localId = local.messageId;
  final serverId = server.messageId;

  // 1. 精确 ID 匹配
  if (localId != null &&
      serverId != null &&
      localId.isNotEmpty &&
      localId == serverId) {
    return true;
  }

  // 若双方都有非本地生成的权威 ID 且不相等，则判定为不同消息
  final localIsAuthoritative = !_isTempId(localId);
  final serverIsAuthoritative = !_isTempId(serverId);
  if (localIsAuthoritative && serverIsAuthoritative) {
    return false;
  }

  // 2. 角色校验
  if (local.role != server.role) return false;

  // 3. 工具调用 ID 匹配
  if (local.toolCallId != null &&
      server.toolCallId != null &&
      local.toolCallId == server.toolCallId) {
    return true;
  }
  if (local.toolUseId != null &&
      server.toolUseId != null &&
      local.toolUseId == server.toolUseId) {
    return true;
  }

  // 4. 指纹匹配：content + timestamp（容差 120s）
  final localContent = local.content ?? '';
  final serverContent = server.content ?? '';
  if (localContent == serverContent) {
    final localTs = local.timestamp;
    final serverTs = server.timestamp;
    if (localTs != null && serverTs != null && localTs > 0 && serverTs > 0) {
      return (localTs - serverTs).abs() <= 120.0;
    }
    return true;
  }

  // 双方 role == 'user' 且精确相等失败时，追加兜底：归一化匹配
  if (local.role == 'user' && server.role == 'user') {
    final normLocal = _normalizeUserContent(localContent);
    final normServer = _normalizeUserContent(serverContent);
    if (normLocal == normServer) {
      final localTs = local.timestamp;
      final serverTs = server.timestamp;
      if (localTs != null && serverTs != null && localTs > 0 && serverTs > 0) {
        return (localTs - serverTs).abs() <= 120.0;
      }
      return true;
    }
  }

  // 5. 本地流式临时 assistant 消息与服务端 assistant 消息匹配（替换占位）
  if (local.role == 'assistant' && _isTempId(localId)) {
    final localTs = local.timestamp;
    final serverTs = server.timestamp;
    final withinTimeWindow =
        localTs == null ||
        serverTs == null ||
        localTs <= 0 ||
        serverTs <= 0 ||
        (localTs - serverTs).abs() <= 120.0;
    if (withinTimeWindow) return true;
    // 内容吸收匹配：流式回合超长（>120s）时时间窗失效，但本地流式内容
    // 与服务端占位行互为前缀（一方是另一方的前缀）即同一回合消息。
    // 不匹配会导致 diff-merge 把污染的 live 消息当「未落库本地项」整条
    // 保留、又补入服务端行 → 同一段文字双份渲染、各自跑打字机（双打字机）。
    final localContent = local.content ?? '';
    final serverContent = server.content ?? '';
    if (localContent.isEmpty || serverContent.isEmpty) return false;
    return localContent.startsWith(serverContent) ||
        serverContent.startsWith(localContent);
  }

  return false;
}

/// 剥离服务端注入标记（[Workspace::v1: ...]、[Attached files: ...]、行级占位符），
/// 归一化展示与比对文本。
String _normalizeUserContent(String raw) {
  var text = raw;
  // 1. 剥离 ^[Workspace::v1: ...] 行（可能带前导换行，容忍转义反斜杠路径与任意后缀）
  text = text.replaceAll(
    RegExp(
      r'^[^\S\r\n]*\[Workspace::v1:[ \t]*[^\]]*\][^\S\r\n]*(?:\r?\n|$)',
      multiLine: true,
      caseSensitive: false,
    ),
    '',
  );
  // 2. 剥离 [Attached files: ...] 段
  text = text.replaceAll(
    RegExp(r'\[Attached files:[ \t]*[^\]]*\]', caseSensitive: false),
    '',
  );
  // 3. 剥离行级占位符 [screenshot]、[image]、[attachment]（整行精确匹配才删，防误伤正文）
  text = text.replaceAll(
    RegExp(
      r'^[^\S\r\n]*\[(screenshot|image|attachment)\][^\S\r\n]*(?:\r?\n|$)',
      multiLine: true,
      caseSensitive: false,
    ),
    '',
  );
  // 4. 归一化后 trim 首尾空白
  return text.trim();
}

bool _isTempId(String? id) {
  if (id == null || id.isEmpty) return true;
  return id.startsWith('local-') || id.startsWith('stream-');
}

ChatMessage _patchMessage(ChatMessage local, ChatMessage server) {
  var content = server.content;
  final localContent = local.content ?? '';
  final serverContent = server.content ?? '';

  if (server.role == 'user') {
    final normalized = _normalizeUserContent(serverContent);
    if (normalized != serverContent) {
      content = normalized.isNotEmpty ? normalized : local.content;
    }
  } else if (localContent.isNotEmpty &&
      serverContent.isNotEmpty &&
      localContent != serverContent &&
      (localContent.startsWith(serverContent) ||
          serverContent.startsWith(localContent))) {
    // 前缀包含去重（chat_spec.md §5.5 最低档）：内容互为前缀时取更长一方
    // （流式中途 transcript 重载常见「服务端 checkpoint 落后本地已展示内容」，
    // 取短会让可见文本回缩）。与 done 路径 _mergingLoadedMessages 语义一致。
    content = localContent.length >= serverContent.length
        ? local.content
        : server.content;
  }
  return server.copyWith(
    content: content,
    turnTps: server.turnTps ?? local.turnTps,
  );
}

void _stableSortMessages(List<ChatMessage> list) {
  final hasTs = list.any((m) => m.timestamp != null && m.timestamp! > 0);
  if (hasTs) {
    list.sort((a, b) {
      final tsA = a.timestamp ?? 0;
      final tsB = b.timestamp ?? 0;
      return tsA.compareTo(tsB);
    });
  }
}

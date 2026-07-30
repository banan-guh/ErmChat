String resolveThreadRootId(String messageId, Map<String, String> parentOf) {
  var cur = messageId;
  while (parentOf.containsKey(cur)) {
    cur = parentOf[cur]!;
  }
  return cur;
}

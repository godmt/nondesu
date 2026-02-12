part of nondesu;

// ====== fingerprint helpers ======

final RegExp _reStrip = RegExp(r'[\s\p{P}\p{S}]', unicode: true);
String _norm(String s) => s.toLowerCase().replaceAll(_reStrip, '');

String _hintOf(String text, {int max = 32}) {
  final t = text.trim().replaceAll('\n', ' ');
  if (t.length <= max) return t;
  return "${t.substring(0, max)}…";
}

int _fnv1a64(String s) {
  const int offset = 0xcbf29ce484222325;
  const int prime = 0x100000001b3;
  const int mask = 0xFFFFFFFFFFFFFFFF;

  int h = offset;
  final bytes = utf8.encode(s);
  for (final b in bytes) {
    h ^= b;
    h = (h * prime) & mask;
  }
  return h & mask;
}

int _simhash64(String text) {
  const int mask = 0xFFFFFFFFFFFFFFFF;
  final n = _norm(text);
  if (n.length < 3) return _fnv1a64(n);

  final acc = List<int>.filled(64, 0);
  for (int i = 0; i <= n.length - 3; i++) {
    final tri = n.substring(i, i + 3);
    final h = _fnv1a64(tri);
    for (int b = 0; b < 64; b++) {
      acc[b] += ((h >> b) & 1) == 1 ? 1 : -1;
    }
  }

  int out = 0;
  for (int b = 0; b < 64; b++) {
    if (acc[b] > 0) out |= (1 << b);
  }
  return out & mask;
}

int _popcount64(int x) {
  int c = 0;
  while (x != 0) {
    x &= (x - 1);
    c++;
  }
  return c;
}

int _hamming64(int a, int b) => _popcount64((a ^ b) & 0xFFFFFFFFFFFFFFFF);

String _hex64(int x) => "0x${x.toRadixString(16).padLeft(16, '0')}";
int _parseHex64(String s) {
  final t = s.startsWith("0x") ? s.substring(2) : s;
  return int.tryParse(t, radix: 16) ?? 0;
}

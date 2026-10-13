/// A release identifier such as `0.42.0+71`, as written in `pubspec.yaml`, in a
/// GitHub tag (`v0.42.0+71`) or in a manifest.
///
/// Android decides whether an install is an update from the build number
/// (`versionCode`) alone, so that is what ordering uses whenever both sides
/// carry one. The dotted name is only a fallback for a source that omits it —
/// and when they disagree the build number wins, because it is the one Android
/// will actually enforce.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion({required this.name, this.build});

  /// Returns null for anything that is not `x.y.z` with an optional `+build`.
  ///
  /// A leading `v` is tolerated because a tag carries one. A `-` before the
  /// build number is also accepted, since release assets are named
  /// `morningcoach-0.42.0-71.apk` and a source may reuse that spelling.
  static AppVersion? tryParse(String raw) {
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) return null;
    final build = match.group(2);
    return AppVersion(
      name: match.group(1)!,
      build: build == null ? null : int.parse(build),
    );
  }

  static final _pattern = RegExp(r'^v?(\d+\.\d+\.\d+)(?:[+-](\d+))?$');

  final String name;
  final int? build;

  bool isNewerThan(AppVersion other) => compareTo(other) > 0;

  @override
  int compareTo(AppVersion other) {
    final mine = build;
    final theirs = other.build;
    if (mine != null && theirs != null && mine != theirs) {
      return mine.compareTo(theirs);
    }
    if (mine != null && theirs != null) return 0;
    return _compareNames(name, other.name);
  }

  static int _compareNames(String a, String b) {
    final left = a.split('.').map(int.parse).toList();
    final right = b.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final order = left[i].compareTo(right[i]);
      if (order != 0) return order;
    }
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion && other.name == name && other.build == build;

  @override
  int get hashCode => Object.hash(name, build);

  @override
  String toString() => build == null ? name : '$name+$build';
}

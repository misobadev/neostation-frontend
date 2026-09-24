/// Paging constants shared by every walk of the RomM server's ROM list.
///
/// Bulk sync's enumeration and the connect-time link pass page the same
/// endpoint the same way, and the pass deliberately uses bulk sync's page
/// size and cap so it costs no more. Both used to declare their own copy — the linker even
/// imported the provider for one of them, a service reaching *up* a layer —
/// so the values live here, in the services layer both can depend on, and
/// are defined exactly once.
abstract final class RommPaging {
  /// Rows per enumeration request. Larger than the browse page size (50):
  /// these walks are a means to an end, not something the user scrolls, so
  /// the round trips matter more than the latency of any one of them.
  static const int pageSize = 500;

  /// Hard stop on a paging loop, in pages. A server that keeps returning full
  /// pages (a `total` that never agrees with the rows, a filter the server
  /// ignores) would otherwise page forever. 500 × 500 = 250k ROMs, far past
  /// any real library.
  static const int maxPages = 500;
}

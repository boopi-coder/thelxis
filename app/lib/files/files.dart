/// File transfer module: one import for the endpoint and the UI widgets.
///
/// The endpoint API is documented in `file_transfer_endpoint.dart`.
library;

export 'file_transfer_endpoint.dart';
export 'ui/file_drop_target.dart' show FileDropTarget;
export 'ui/file_transfer_panel.dart' show FileTransferPanel;
export 'ui/files_strings.dart' show FilesStrings;
export 'ui/pick_and_send.dart' show PickKind, SendFilesMenuButton, pickAndSendFiles, sendPathsWithFeedback;
export 'ui/transfers_tab.dart' show revealInFolder;

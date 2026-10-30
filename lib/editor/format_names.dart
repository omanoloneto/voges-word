import '../document/document_codec.dart';
import '../l10n/l10n.dart';

/// The format's name with its extension, as Save as and Share list it.
String formatName(AppLocalizations l10n, DocumentFormat format) =>
    switch (format) {
      DocumentFormat.docx => l10n.formatDocx,
      DocumentFormat.docm => l10n.formatDocm,
      DocumentFormat.doc => l10n.formatDoc,
      DocumentFormat.odt => l10n.formatOdt,
      DocumentFormat.rtf => l10n.formatRtf,
      DocumentFormat.html => l10n.formatHtml,
      DocumentFormat.markdown => l10n.formatMarkdown,
      DocumentFormat.plainText => l10n.formatPlainText,
    };

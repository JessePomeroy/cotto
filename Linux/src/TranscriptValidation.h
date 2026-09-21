#pragma once

#include <QString>

namespace sotto {
// Reject rather than transform text that could change terminal semantics. This
// check protects both the desktop paste path and the Pi bridge boundary.
inline QString transcriptRejection(const QString &text) {
    if (text.isEmpty()) return QStringLiteral("No speech to insert.");
    if (text.size() > 64 * 1024 || text.toUtf8().size() > 64 * 1024)
        return QStringLiteral("Not inserted: text exceeds the delivery limit. Review the saved transcript.");
    if (!text.isValidUtf16())
        return QStringLiteral("Not inserted: text contains invalid Unicode. Review the saved transcript.");
    for (const auto character : text.toUcs4()) {
        const auto category = QChar::category(character);
        if (category == QChar::Other_Control || category == QChar::Other_Format
            || category == QChar::Separator_Line || category == QChar::Separator_Paragraph) {
            return QStringLiteral("Not inserted: line breaks or control characters require manual review. Copy preserves the original text.");
        }
    }
    if (text.trimmed().isEmpty()) return QStringLiteral("No speech to insert.");
    return {};
}
} // namespace sotto

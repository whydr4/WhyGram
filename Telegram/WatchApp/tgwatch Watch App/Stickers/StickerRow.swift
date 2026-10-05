import Foundation
import TDShim

/// Builds a `StickerVisual` for content drawn as a sticker: `messageSticker`; a lone
/// emoji sent on its own (`messageAnimatedEmoji`, with its animated sticker); a dice
/// roll's final state (`messageDice` / `messageStakeDice`, regular dice only — the slot
/// machine is several layered stickers). Returns `nil` for anything else, and for an
/// animated emoji or roll without a usable sticker, which then fall back to text
/// (`messageBody`). Looks up the sticker's file id (and its thumbnail file id if
/// present) in `fileLocals` for the freshest local-path snapshot.
func stickerVisual(for content: MessageContent, fileLocals: [Int: File]) -> StickerVisual? {
    switch content {
    case .messageSticker(let m):
        return stickerVisual(m.sticker, fileLocals: fileLocals)
    case .messageAnimatedEmoji(let m):
        // A skin-toned emoji needs its sticker recolored (Telegram swaps the colors by
        // `fitzpatrickType`); the plain text emoji has the right tone already.
        guard let sticker = m.animatedEmoji.sticker, m.animatedEmoji.fitzpatrickType == 0 else { return nil }
        var visual = stickerVisual(sticker, fileLocals: fileLocals)
        visual.isAnimatedEmoji = true
        return visual
    case .messageDice(let m):
        guard case .diceStickersRegular(let r) = m.finalState else { return nil }
        return stickerVisual(r.sticker, fileLocals: fileLocals)
    case .messageStakeDice(let m):
        guard case .diceStickersRegular(let r) = m.finalState else { return nil }
        return stickerVisual(r.sticker, fileLocals: fileLocals)
    default:
        return nil
    }
}

private func stickerVisual(_ sticker: Sticker, fileLocals: [Int: File]) -> StickerVisual {
    let mainFile = fileLocals[sticker.sticker.id] ?? sticker.sticker
    let localPath: String? = (mainFile.local.isDownloadingCompleted && !mainFile.local.path.isEmpty)
        ? mainFile.local.path : nil

    var thumbnailFileId: Int? = nil
    var thumbnailLocalPath: String? = nil
    var thumbnailFormat: ThumbnailFormatKind? = nil
    if let thumb = sticker.thumbnail {
        let kind = thumbnailFormatKind(thumb.format)
        thumbnailFormat = kind
        if kind != .unsupported {
            thumbnailFileId = thumb.file.id
            let thumbFile = fileLocals[thumb.file.id] ?? thumb.file
            if thumbFile.local.isDownloadingCompleted && !thumbFile.local.path.isEmpty {
                thumbnailLocalPath = thumbFile.local.path
            }
        }
    }

    return StickerVisual(
        fileId: sticker.sticker.id,
        format: stickerFormatKind(sticker.format),
        width: sticker.width,
        height: sticker.height,
        emoji: sticker.emoji,
        localPath: localPath,
        thumbnailFileId: thumbnailFileId,
        thumbnailLocalPath: thumbnailLocalPath,
        thumbnailFormat: thumbnailFormat
    )
}

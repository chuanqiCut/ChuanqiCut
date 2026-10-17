#if os(iOS)
import AVFoundation
import Combine
import SnapKit
import TimelineKit
import UIKit
import SwiftUI

public struct TimelineKitIntegrationScreen: UIViewControllerRepresentable {
  public init() {}

  public func makeUIViewController(context: Context) -> TimelineKitIntegrationPreview {
    TimelineKitIntegrationPreview()
  }

  public func updateUIViewController(
    _ uiViewController: TimelineKitIntegrationPreview, context: Context
  ) {}
}

/// DEBUG-only integration surface for exercising the local TimelineKit pod in the host app.
/// It intentionally uses an isolated sample project; production editing continues to use the
/// editor's command-backed timeline until an explicit model adapter is designed.
@MainActor
public final class TimelineKitIntegrationPreview: UIViewController {
  private let canvas = TimelineEditCanvasView()
  private let maskEditor = TimelineMaskEditorView()
  private let previewStage = UIView()
  private let modePicker = UISegmentedControl(items: ["画布多选", "蒙版参数"])
  private let statusLabel = UILabel()
  private var subscriptions = Set<AnyCancellable>()
  private var didCenterMask = false

  public init() {
    super.init(nibName: nil, bundle: nil)
    title = "TimelineKit 集成预览"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

  public override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(white: 0.055, alpha: 1)
    buildPreviewStage()
    buildTimeline()
  }

  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard !didCenterMask, previewStage.bounds.width > 0 else { return }
    didCenterMask = true
    maskEditor.maskModel = try? TimelineMask(
      id: "preview-mask", shape: .rectangle,
      size: TimelineSize(width: min(240, previewStage.bounds.width - 40), height: 118),
      center: TimelinePoint(x: previewStage.bounds.midX, y: previewStage.bounds.midY),
      cornerRadius: 20, feather: 8)
  }

  private func buildPreviewStage() {
    let title = UILabel()
    title.text = "Local CocoaPods · UIKit · Combine"
    title.textColor = .white
    title.font = .systemFont(ofSize: 15, weight: .semibold)

    modePicker.selectedSegmentIndex = 0
    modePicker.addTarget(self, action: #selector(changePreviewMode), for: .valueChanged)

    previewStage.backgroundColor = UIColor(white: 0.12, alpha: 1)
    previewStage.layer.cornerRadius = 14
    previewStage.clipsToBounds = true
    canvas.imageProvider = { [weak self] item in self?.overlayImages[item.resourceID] }
    canvas.backgroundColor = .clear
    maskEditor.showsParameterControls = true
    maskEditor.outlineColor = .systemCyan
    maskEditor.isHidden = true
    previewStage.addSubview(canvas)
    previewStage.addSubview(maskEditor)
    canvas.snp.makeConstraints { $0.edges.equalToSuperview() }
    maskEditor.snp.makeConstraints { $0.edges.equalToSuperview() }

    statusLabel.text = "拖动标记编辑时间线 · 双指点按切换画布多选"
    statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.numberOfLines = 2

    let stack = UIStackView(arrangedSubviews: [title, modePicker, previewStage, statusLabel])
    stack.axis = .vertical
    stack.spacing = 10
    view.addSubview(stack)
    stack.snp.makeConstraints { make in
      make.top.equalTo(view.safeAreaLayoutGuide).offset(12)
      make.left.right.equalToSuperview().inset(16)
      make.height.equalTo(300)
    }
    previewStage.snp.makeConstraints { $0.height.equalTo(208) }

    do {
      let itemA = try TimelineEditItem(
        id: "canvas-title", resourceID: "title-card", size: TimelineSize(width: 150, height: 74),
        transform: TimelineTransform(translation: TimelinePoint(x: -48, y: 8)), zIndex: 1)
      let itemB = try TimelineEditItem(
        id: "canvas-sticker", resourceID: "sticker-card", size: TimelineSize(width: 112, height: 82),
        transform: TimelineTransform(translation: TimelinePoint(x: 58, y: -18), rotationRadians: -0.12), zIndex: 2)
      overlayImages = [
        "title-card": makeCardImage(title: "标题图层", color: UIColor.systemIndigo),
        "sticker-card": makeCardImage(title: "贴纸", color: UIColor.systemPink),
      ]
      canvas.update(items: [itemA, itemB], selectedItemIDs: [itemA.id, itemB.id])
    } catch {
      statusLabel.text = "画布样例初始化失败：\(error)"
    }
  }

  private var overlayImages: [String: UIImage] = [:]

  private func buildTimeline() {
    do {
      if let media = localTestMediaURLs(),
         FileManager.default.fileExists(atPath: media.video.path),
         FileManager.default.fileExists(atPath: media.videoB.path),
         FileManager.default.fileExists(atPath: media.videoC.path),
         FileManager.default.fileExists(atPath: media.audio.path) {
        buildTimeline(videoURL: media.video, videoBURL: media.videoB, videoCURL: media.videoC, audioURL: media.audio)
        return
      }
      let first = try TimelineClip(
        id: "video-a", kind: .video,
        timelineRange: timeRange(0, 4), sourceRange: timeRange(0, 4), title: "片段 A")
      let second = try TimelineClip(
        id: "video-b", kind: .video,
        timelineRange: timeRange(4, 4), sourceRange: timeRange(0, 4), title: "片段 B")
      let music = try TimelineClip(
        id: "music-a", kind: .audio,
        timelineRange: timeRange(0.5, 7), sourceRange: timeRange(0, 7), title: "配乐示例")
      let titleClip = try TimelineClip(
        id: "title-a", kind: .title,
        timelineRange: timeRange(1, 3), title: "标题示例")
      let videoTrack = try TimelineTrack(
        id: "track-video", name: "主视频", kind: .primaryVideo, role: .primary,
        clips: [first, second], rowHeight: 54, overlapPolicy: .reject)
      let audioTrack = try TimelineTrack(
        id: "track-audio", name: "音频", kind: .audio, clips: [music], rowHeight: 48)
      let titleTrack = try TimelineTrack(
        id: "track-title", name: "标题", kind: .text, clips: [titleClip], rowHeight: 48)
      let keyframes = [
        try TimelineKeyframe(id: "key-a", clipID: first.id, sourceTime: time(1), values: ["scale": 1]),
        try TimelineKeyframe(id: "key-b", clipID: first.id, sourceTime: time(2.5), values: ["scale": 1.2]),
      ]
      let transition = try TimelineTransition(
        id: "transition-ab", leadingClipID: first.id, trailingClipID: second.id,
        duration: time(0.8), styleID: "crossDissolve")
      let project = try TimelineProject(
        id: "timelinekit-host-preview", tracks: [videoTrack, audioTrack, titleTrack],
        transitions: [transition], keyframes: keyframes, frameRate: .fps30)
      let projectStore = try TimelineStore(project: project)
      try projectStore.selectClip(id: first.id)
      let style = TimelineStyle(initialPixelsPerSecond: 58, contentTailInset: 52)
      let timelineView = TimelineKit.TimelineView(store: projectStore, style: style)
      timelineView.backgroundColor = UIColor(white: 0.08, alpha: 1)
      view.addSubview(timelineView)
      timelineView.snp.makeConstraints { make in
        make.left.right.equalToSuperview()
        make.top.equalTo(view.safeAreaLayoutGuide).offset(326)
        make.height.equalTo(236)
      }
      timelineView.events
        .sink { [weak self] event in self?.describe(event) }
        .store(in: &subscriptions)
    } catch {
      statusLabel.text = "时间线样例初始化失败：\(error)"
    }
  }

  private func localTestMediaURLs() -> (video: URL, videoB: URL, videoC: URL, audio: URL)? {
    guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    else { return nil }
    let folder = documents.appendingPathComponent("TimelineKitTestAssets", isDirectory: true)
    return (
      folder.appendingPathComponent("IMG_0508.MOV"),
      folder.appendingPathComponent("IMG_0137.MP4"),
      folder.appendingPathComponent("v0300fg10000d7ccafnog65qk7ji9lvg.MP4"),
      folder.appendingPathComponent("timeline-music.mp3"))
  }

  private func buildTimeline(videoURL: URL, videoBURL: URL, videoCURL: URL, audioURL: URL) {
    do {
      let audioDuration = time(265.247)
      let videoAssets = [
        try TimelineMediaAsset(
          id: "local-video-a", locator: videoURL.absoluteString, kind: .video,
          duration: time(26.53755), pixelWidth: 1280, pixelHeight: 720,
          hasAudio: true, hasVideo: true),
        try TimelineMediaAsset(
          id: "local-video-b", locator: videoBURL.absoluteString, kind: .video,
          duration: time(26.53755), pixelWidth: 1280, pixelHeight: 720,
          hasAudio: true, hasVideo: true),
        try TimelineMediaAsset(
          id: "local-video-c", locator: videoCURL.absoluteString, kind: .video,
          duration: time(26.53755), pixelWidth: 1280, pixelHeight: 720,
          hasAudio: true, hasVideo: true),
      ]
      let audioAsset = try TimelineMediaAsset(
        id: "local-music", locator: audioURL.absoluteString, kind: .audio,
        duration: audioDuration, hasAudio: true)

      let primaryClips = try [
        TimelineClip(
          id: "local-video-clip-a", mediaID: videoAssets[0].id, kind: .video,
          timelineRange: timeRange(0, 8), sourceRange: timeRange(1, 8),
          title: "本机 MP4 · 视频片段 A"),
        TimelineClip(
          id: "local-video-clip-b", mediaID: videoAssets[1].id, kind: .video,
          timelineRange: timeRange(8, 8), sourceRange: timeRange(2, 8),
          title: "本机 MP4 · 视频片段 B"),
        TimelineClip(
          id: "local-video-clip-c", mediaID: videoAssets[2].id, kind: .video,
          timelineRange: timeRange(16, 8), sourceRange: timeRange(1, 8),
          title: "本机上传 MP4 · 视频片段 C"),
      ]
      let musicRange = timeRange(0, 20)
      let music = try TimelineClip(
        id: "local-music-clip", mediaID: audioAsset.id, kind: .audio,
        timelineRange: timeRange(0, 20), sourceRange: musicRange,
        title: "本机音乐 · 波形")
      let primary = try TimelineTrack(
        id: "track-video", name: "主视频（置顶）", kind: .primaryVideo, role: .primary,
        clips: primaryClips, rowHeight: 62, overlapPolicy: .reject)
      let overlayVideoClip = try TimelineClip(
        id: "overlay-video-blocker", mediaID: videoAssets[0].id, kind: .video,
        timelineRange: timeRange(0, 30), sourceRange: timeRange(10, 8),
        title: "视频副轨 · 满位测试")
      let overlayVideo = try TimelineTrack(
        id: "track-video-overlay", name: "视频副轨", kind: .video,
        clips: [overlayVideoClip], rowHeight: 54, overlapPolicy: .reject)
      let audio = try TimelineTrack(
        id: "track-audio", name: "音频副轨", kind: .audio,
        clips: [music], rowHeight: 58)
      let overlayClip = try TimelineClip(
        id: "overlay-sample", kind: .sticker, timelineRange: timeRange(1.5, 2),
        title: "贴纸副轨")
      let titleClip = try TimelineClip(
        id: "title-sample", kind: .title, timelineRange: timeRange(0.5, 2.5),
        title: "标题副轨")
      let effectClip = try TimelineClip(
        id: "effect-sample", kind: .effect, timelineRange: timeRange(1, 2),
        title: "效果副轨")
      let overlay = try TimelineTrack(
        id: "track-overlay", name: "贴纸副轨", kind: .sticker,
        clips: [overlayClip], rowHeight: 50)
      let titleTrack = try TimelineTrack(
        id: "track-title", name: "标题副轨", kind: .text,
        clips: [titleClip], rowHeight: 50)
      let effect = try TimelineTrack(
        id: "track-effect", name: "效果副轨", kind: .effect,
        clips: [effectClip], rowHeight: 50)
      let project = try TimelineProject(
        id: "timelinekit-local-media-check", tracks: [primary, overlayVideo, audio, overlay, titleTrack, effect],
        mediaAssets: videoAssets + [audioAsset], frameRate: .fps30,
        durationPolicy: .longestEnabledClip)
      let store = try TimelineStore(project: project)
      try store.selectClip(id: primaryClips[0].id)
      let timelineView = TimelineKit.TimelineView(
        store: store, style: TimelineStyle(initialPixelsPerSecond: 70, contentTailInset: 52))
      timelineView.backgroundColor = UIColor(white: 0.08, alpha: 1)
      view.addSubview(timelineView)
      timelineView.snp.makeConstraints { make in
        make.left.right.equalToSuperview()
        make.top.equalTo(view.safeAreaLayoutGuide).offset(326)
        make.height.equalTo(236)
      }
      timelineView.events
        .sink { [weak self] event in self?.describe(event) }
        .store(in: &subscriptions)

      statusLabel.text = "主轨含 3 段本机视频：长按同轨排序，拖到副轨；副轨无空位时自动新增轨道 · 30 fps"
      let thumbnail = AVFoundationThumbnailProvider()
      thumbnail.thumbnail(
        asset: AVURLAsset(url: videoCURL), at: time(1), targetSize: CGSize(width: 144, height: 96))
        .receive(on: DispatchQueue.main)
        .sink(receiveCompletion: { [weak self] completion in
          if case .failure(let error) = completion {
            print("[TimelineKitMediaSmoke] thumbnail=FAIL \(error)")
            self?.statusLabel.text = "视频缩略图失败：\(error.localizedDescription)"
          }
        }, receiveValue: { [weak self] _ in
          print("[TimelineKitMediaSmoke] thumbnail=PASS")
          self?.statusLabel.text = "视频缩略图解码成功 · 正在显示本机音乐波形"
        })
        .store(in: &subscriptions)
      let waveform = AVFoundationWaveformProvider()
      waveform.waveform(asset: AVURLAsset(url: audioURL), range: musicRange, pointCount: 480)
        .receive(on: DispatchQueue.main)
        .sink(receiveCompletion: { [weak self] completion in
          if case .failure(let error) = completion {
            print("[TimelineKitMediaSmoke] waveform=FAIL \(error)")
            self?.statusLabel.text = "音频波形解码失败：\(error.localizedDescription)"
          }
        }, receiveValue: { [weak self] bins in
          print("[TimelineKitMediaSmoke] waveform=PASS bins=\(bins.count)")
          self?.statusLabel.text = "本机素材验证成功：视频缩略图 + 音频波形 \(bins.count) 格 · 可拖边缘改长度"
        })
        .store(in: &subscriptions)
    } catch {
      statusLabel.text = "本机素材工程初始化失败：\(error)"
    }
  }

  @objc private func changePreviewMode() {
    let showingMask = modePicker.selectedSegmentIndex == 1
    canvas.isHidden = showingMask
    maskEditor.isHidden = !showingMask
    statusLabel.text = showingMask
      ? "蒙版参数：拖动、旋转、缩放；在预览区底部调整圆角和羽化"
      : "拖动标记编辑时间线 · 双指点按切换画布多选"
  }

  private func describe(_ event: TimelineViewEvent) {
    switch event {
    case .clipTrimBegan(_, let edge, _):
      let edgeName = edge == .leading ? "左边缘" : "右边缘"
      statusLabel.text = "拖动\(edgeName)：改变片段长度，播放速度保持不变"
    case .clipTrimPreview(let id, let edge, let range, _):
      let edgeName = edge == .leading ? "左裁剪" : "右裁剪/延长"
      statusLabel.text = "\(edgeName)预览：\(String(format: "%.2f", range.duration.seconds)) 秒"
      print("[TimelineKitTrimSmoke] preview id=\(id) edge=\(edgeName) duration=\(range.duration.seconds)")
    case .clipTrimCommitted(let id, let edge, let range, _):
      let edgeName = edge == .leading ? "左边缘" : "右边缘"
      statusLabel.text = "\(edgeName)已提交：\(String(format: "%.2f", range.duration.seconds)) 秒"
      print("[TimelineKitTrimSmoke] commit id=\(id) edge=\(edgeName) duration=\(range.duration.seconds)")
    case .clipTrimCancelled(let id, _, _):
      statusLabel.text = "边缘拉伸已取消：\(id)"
    case .keyframeEditPreview(let value):
      statusLabel.text = "关键帧预览：\(value.id) · \(String(format: "%.2f", value.sourceTime.seconds))s"
    case .keyframeEditCommitted(let value):
      statusLabel.text = "关键帧已提交：\(value.id)"
    case .transitionEditPreview(let value):
      statusLabel.text = "转场时长：\(String(format: "%.2f", value.duration.seconds))s"
    case .transitionEditCommitted:
      statusLabel.text = "转场时长已提交"
    case .clipMovePreview(_, let trackID, let start, let isValid, _):
      statusLabel.text = "移动预览：\(trackID) · \(String(format: "%.2f", start.seconds))s · \(isValid ? "可放置" : "有冲突")"
    case .tailInsertionRequested(let trackID, let at):
      statusLabel.text = "尾部插入入口：\(trackID) @ \(String(format: "%.2f", at.seconds))s"
    case .editRejected(let error):
      statusLabel.text = "编辑被拒绝：\(error)"
    default:
      break
    }
  }

  private func time(_ seconds: Double) -> TimelineTime {
    try! TimelineTime(seconds: seconds)
  }

  private func timeRange(_ start: Double, _ duration: Double) -> TimelineTimeRange {
    try! TimelineTimeRange(start: time(start), duration: time(duration))
  }

  private func makeCardImage(title: String, color: UIColor) -> UIImage {
    let size = CGSize(width: 360, height: 190)
    return UIGraphicsImageRenderer(size: size).image { context in
      let rect = CGRect(origin: .zero, size: size)
      color.setFill()
      UIBezierPath(roundedRect: rect, cornerRadius: 24).fill()
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: UIColor.white,
      ]
      let text = title as NSString
      let textSize = text.size(withAttributes: attributes)
      text.draw(
        at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
        withAttributes: attributes)
      context.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.7).cgColor)
      context.cgContext.setLineWidth(4)
      context.cgContext.stroke(rect.insetBy(dx: 5, dy: 5))
    }
  }
}
#endif

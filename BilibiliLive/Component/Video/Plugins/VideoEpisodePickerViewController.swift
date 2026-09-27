import SnapKit
import UIKit

final class VideoEpisodePickerViewController: UIViewController {
    var onClose: ((VideoEpisodeList.Selection?) -> Void)?

    private let episodes: VideoEpisodeList
    private let currentPlayInfo: PlayInfo
    private let pages: [VideoEpisodeList.Page]
    private(set) var selectedPageIndex = 0
    private var preferredEpisodeIndexPath = IndexPath(item: 0, section: 0)
    private var isClosing = false
    private let sectionLabel = UILabel()
    private let closeButton = BLCustomTextButton()

    private lazy var rangesView = makeCollectionView(rowHeight: 96, identifier: "episode-ranges")
    private lazy var episodesView = makeCollectionView(rowHeight: 104, identifier: "episode-list")

    init(episodes: VideoEpisodeList, currentPlayInfo: PlayInfo, preferredSectionID: String?) {
        self.episodes = episodes
        self.currentPlayInfo = currentPlayInfo
        pages = episodes.pages
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        if let section = episodes.section(for: currentPlayInfo, preferredID: preferredSectionID),
           let index = section.index(of: currentPlayInfo),
           let pageIndex = pages.firstIndex(where: {
               episodes.sections[$0.sectionIndex].id == section.id && $0.range.contains(index)
           })
        {
            selectedPageIndex = pageIndex
            preferredEpisodeIndexPath = IndexPath(item: index - pages[pageIndex].range.lowerBound, section: 0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "episode-picker"
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)

        let panel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        panel.layer.cornerRadius = 24
        panel.clipsToBounds = true
        view.addSubview(panel)
        panel.snp.makeConstraints {
            $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
            $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(12)
            $0.height.equalTo(view.snp.height).multipliedBy(0.78)
        }

        let titleLabel = UILabel()
        titleLabel.text = "选集"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 38, weight: .semibold)
        panel.contentView.addSubview(titleLabel)
        titleLabel.snp.makeConstraints {
            $0.top.leading.equalToSuperview().inset(36)
            $0.height.equalTo(50)
        }

        closeButton.title = "返回"
        closeButton.accessibilityIdentifier = "episode-picker-close"
        closeButton.onPrimaryAction = { [weak self] _ in self?.close() }
        panel.contentView.addSubview(closeButton)
        closeButton.snp.makeConstraints {
            $0.centerY.equalTo(titleLabel)
            $0.trailing.equalToSuperview().inset(44)
            $0.width.equalTo(150)
            $0.height.equalTo(56)
        }

        sectionLabel.font = .systemFont(ofSize: 26, weight: .medium)
        sectionLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        panel.contentView.addSubview(sectionLabel)
        sectionLabel.snp.makeConstraints {
            $0.top.equalTo(titleLabel.snp.bottom).offset(12)
            $0.leading.trailing.equalToSuperview().inset(40)
            $0.height.equalTo(40)
        }

        let columns = UIStackView(arrangedSubviews: [rangesView, episodesView])
        columns.axis = .horizontal
        columns.spacing = 24
        panel.contentView.addSubview(columns)
        columns.snp.makeConstraints {
            $0.top.equalTo(sectionLabel.snp.bottom).offset(12)
            $0.leading.trailing.equalToSuperview().inset(24)
            $0.bottom.equalToSuperview().inset(62)
        }
        rangesView.snp.makeConstraints { $0.width.equalTo(360) }
        rangesView.isHidden = pages.count <= 1

        let hintLabel = UILabel()
        hintLabel.text = "按返回键收起 · 按确认键切换剧集"
        hintLabel.font = .systemFont(ofSize: 22)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        panel.contentView.addSubview(hintLabel)
        hintLabel.snp.makeConstraints {
            $0.leading.equalToSuperview().inset(40)
            $0.bottom.equalToSuperview().inset(22)
        }
        updatePage()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        focusEpisode(at: preferredEpisodeIndexPath)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        pages.isEmpty ? [closeButton] : [episodesView]
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            close()
            return
        }
        if presses.contains(where: { $0.type == .playPause }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu || $0.type == .playPause }) { return }
        super.pressesEnded(presses, with: event)
    }

    func close() {
        finish(selection: nil)
    }

    private func finish(selection: VideoEpisodeList.Selection?) {
        guard !isClosing else { return }
        isClosing = true
        let onClose = onClose
        dismiss(animated: true) { onClose?(selection) }
    }

    private func makeCollectionView(rowHeight: CGFloat, identifier: String) -> UICollectionView {
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(rowHeight)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 18
        section.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 16, bottom: 24, trailing: 16)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        collection.backgroundColor = .clear
        collection.accessibilityIdentifier = identifier
        collection.dataSource = self
        collection.delegate = self
        collection.register(BLSettingLineCollectionViewCell.self, forCellWithReuseIdentifier: "range")
        collection.register(VideoEpisodePickerCell.self, forCellWithReuseIdentifier: "episode")
        return collection
    }

    private func updatePage() {
        guard pages.indices.contains(selectedPageIndex) else {
            sectionLabel.text = "当前没有可选剧集"
            return
        }
        let page = pages[selectedPageIndex]
        let section = episodes.sections[page.sectionIndex]
        sectionLabel.text = "\(section.title) · 共 \(section.items.count) 集"
        episodesView.reloadData()
        rangesView.selectItem(at: IndexPath(item: selectedPageIndex, section: 0), animated: false, scrollPosition: .centeredVertically)
    }

    func focusEpisode(at indexPath: IndexPath) {
        guard pages.indices.contains(selectedPageIndex),
              indexPath.section == 0, (0..<pages[selectedPageIndex].range.count).contains(indexPath.item)
        else {
            Logger.warn("选集焦点位置无效: \(indexPath)")
            return
        }
        preferredEpisodeIndexPath = indexPath
        episodesView.layoutIfNeeded()
        episodesView.scrollToItem(at: preferredEpisodeIndexPath, at: .centeredVertically, animated: false)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

extension VideoEpisodePickerViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if collectionView === rangesView { return pages.count }
        return pages.indices.contains(selectedPageIndex) ? pages[selectedPageIndex].range.count : 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if collectionView === rangesView {
            let page = pages[indexPath.item]
            let section = episodes.sections[page.sectionIndex]
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "range", for: indexPath) as! BLSettingLineCollectionViewCell
            cell.titleLabel.font = .systemFont(ofSize: 26, weight: .medium)
            cell.titleLabel.numberOfLines = 2
            let range = "\(page.range.lowerBound + 1)–\(page.range.upperBound)"
            cell.titleLabel.text = section.items.count > 20 ? "\(section.title)\n\(range)" : section.title
            cell.accessibilityLabel = cell.titleLabel.text
            return cell
        }
        let page = pages[selectedPageIndex]
        let section = episodes.sections[page.sectionIndex]
        let index = page.range.lowerBound + indexPath.item
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "episode", for: indexPath) as! VideoEpisodePickerCell
        cell.configure(number: index + 1, title: section.items[index].title ?? "第 \(index + 1) 集",
                       isPlaying: section.index(of: currentPlayInfo) == index)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === rangesView {
            selectedPageIndex = indexPath.item
            let page = pages[selectedPageIndex]
            let currentIndex = episodes.sections[page.sectionIndex].index(of: currentPlayInfo)
            let index = currentIndex.flatMap { page.range.contains($0) ? $0 - page.range.lowerBound : nil } ?? 0
            updatePage()
            focusEpisode(at: IndexPath(item: index, section: 0))
            return
        }
        let page = pages[selectedPageIndex]
        let section = episodes.sections[page.sectionIndex]
        let index = page.range.lowerBound + indexPath.item
        let selection = section.index(of: currentPlayInfo) == index ? nil
            : VideoEpisodeList.Selection(sectionID: section.id, index: index)
        finish(selection: selection)
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        if collectionView === rangesView { return IndexPath(item: selectedPageIndex, section: 0) }
        return pages.isEmpty ? nil : preferredEpisodeIndexPath
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        if collectionView === episodesView, let indexPath = context.nextFocusedIndexPath {
            preferredEpisodeIndexPath = indexPath
        }
    }
}

private final class VideoEpisodePickerCell: BLMotionCollectionViewCell {
    private let background = UIView()
    private let numberLabel = UILabel()
    private let titleLabel = UILabel()
    private let playingLabel = UILabel()

    override func setup() {
        super.setup()
        scaleFactor = 1.03
        background.layer.cornerRadius = 14
        contentView.addSubview(background)
        background.snp.makeConstraints { $0.edges.equalToSuperview() }
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
        numberLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 28, weight: .medium)
        titleLabel.numberOfLines = 2
        playingLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        playingLabel.text = "正在播放"
        for label in [numberLabel, titleLabel, playingLabel] { contentView.addSubview(label) }
        numberLabel.snp.makeConstraints {
            $0.leading.equalToSuperview().inset(16)
            $0.centerY.equalToSuperview()
            $0.width.equalTo(68)
        }
        playingLabel.snp.makeConstraints {
            $0.trailing.equalToSuperview().inset(24)
            $0.centerY.equalToSuperview()
            $0.width.equalTo(100)
        }
        titleLabel.snp.makeConstraints {
            $0.leading.equalTo(numberLabel.snp.trailing).offset(12)
            $0.trailing.equalTo(playingLabel.snp.leading).offset(-16)
            $0.centerY.equalToSuperview()
        }
        isAccessibilityElement = true
        updateColors()
    }

    func configure(number: Int, title: String, isPlaying: Bool) {
        numberLabel.text = String(number)
        titleLabel.text = title
        playingLabel.isHidden = !isPlaying
        accessibilityLabel = "\(number). \(title)" + (isPlaying ? "，正在播放" : "")
        accessibilityTraits = isPlaying ? [.button, .selected] : .button
        updateColors()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { self.updateColors() }
    }

    private func updateColors() {
        background.backgroundColor = isFocused ? .white : UIColor.white.withAlphaComponent(0.1)
        for label in [numberLabel, titleLabel, playingLabel] {
            label.textColor = isFocused ? .black : .white
        }
    }
}

import UIKit
import SnapKit
import CoreImage

final class LoginViewController: UIViewController {
    private let ciContext = CIContext()
    private let qrcodeImageView = UIImageView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var timer: Timer?
    private var oauthKey = ""
    private var generation = 0
    private var polling = false
    private var active = false
    private var deadline = Date()
    private let gradient = CAGradientLayer()

    static func create() -> LoginViewController { LoginViewController() }
    override func viewDidLoad() { super.viewDidLoad(); setupUI() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        active = true
        initValidation()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        active = false
        generation += 1
        timer?.invalidate()
        timer = nil
        qrcodeImageView.image = nil
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); gradient.frame = view.bounds }
    deinit { timer?.invalidate() }

    func generateQRCode(from string: String) -> UIImage? {
        guard
            let data = string.data(using: .ascii),
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let extent = outputImage.extent.integral
        guard !extent.isEmpty else { return nil }

        let targetSize: CGFloat = 540
        let scale = max(1, floor(targetSize / max(extent.width, extent.height)))
        let width = Int(extent.width * scale)
        let height = Int(extent.height * scale)

        guard
            let cgImage = ciContext.createCGImage(outputImage, from: extent),
            let bitmapContext = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            return nil
        }

        bitmapContext.interpolationQuality = .none
        bitmapContext.scaleBy(x: scale, y: scale)
        bitmapContext.draw(cgImage, in: extent)

        guard let scaledImage = bitmapContext.makeImage() else { return nil }
        return UIImage(cgImage: scaledImage)
    }


    private func initValidation() {
        guard active else { return }
        generation += 1
        let requestGeneration = generation
        timer?.invalidate()
        timer = nil
        polling = false
        oauthKey = ""
        qrcodeImageView.image = nil
        spinner.startAnimating()
        statusLabel.text = "正在生成安全登录二维码…"
        ApiRequest.requestLoginQR(onFailure: { [weak self] _ in
            guard let self, self.active, self.generation == requestGeneration else { return }
            self.spinner.stopAnimating()
            self.statusLabel.text = "二维码加载失败，请检查网络后重试。"
        }) { [weak self] code, url in
            guard let self, self.active, self.generation == requestGeneration else { return }
            self.spinner.stopAnimating()
            self.qrcodeImageView.image = self.generateQRCode(from: url)
            self.oauthKey = code
            self.deadline = Date().addingTimeInterval(180)
            self.statusLabel.text = "请用哔哩哔哩 App 扫码，并在手机上确认"
            self.timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        }
    }
    private func poll() {
        guard active, !polling, !oauthKey.isEmpty else { return }
        guard Date() < deadline else {
            timer?.invalidate()
            qrcodeImageView.image = nil
            statusLabel.text = "二维码已过期，请刷新后重新扫码。"
            return
        }
        polling = true
        let requestGeneration = generation
        ApiRequest.verifyLoginQR(code: oauthKey) { [weak self] state in
            guard let self, self.active, self.generation == requestGeneration else { return }
            self.polling = false
            switch state {
            case .waiting: break
            case .expire:
                self.timer?.invalidate()
                self.qrcodeImageView.image = nil
                self.statusLabel.text = "二维码已过期，请刷新后重新扫码。"
            case .fail:
                self.statusLabel.text = "连接暂时中断，正在重试…"
            case let .success(token, cookies):
                self.timer?.invalidate()
                self.polling = true
                self.statusLabel.text = "登录成功，正在准备你的空间…"
                AccountManager.shared.registerAccount(token: token, cookies: cookies) { [weak self] _ in
                    guard let self, self.active, self.generation == requestGeneration else { return }
                    AppDelegate.shared.showTabBar()
                }
            }
        }
    }
    private func setupUI() {
        view.backgroundColor = .black
        gradient.colors = [UIColor(red: 0.12, green: 0.17, blue: 0.25, alpha: 1).cgColor, UIColor(white: 0.025, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        view.layer.insertSublayer(gradient, at: 0)

        let left = UIStackView()
        left.axis = .vertical
        left.alignment = .leading
        left.spacing = 28
        view.addSubview(left)
        left.snp.makeConstraints { make in
            make.leading.equalTo(view.safeAreaLayoutGuide).offset(55)
            make.centerY.equalToSuperview().offset(-25)
            make.width.equalToSuperview().multipliedBy(0.46)
        }
        func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = .white) -> UILabel {
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = color
            label.numberOfLines = 0
            return label
        }
        left.addArrangedSubview(label("BILILIVING", size: 24, weight: .semibold, color: .lightGray))
        left.addArrangedSubview(label("好视频，\n值得在大屏看。", size: 68, weight: .bold))
        left.addArrangedSubview(label("用熟悉的账号，回到喜欢的世界。", size: 28, color: .lightGray))
        left.setCustomSpacing(50, after: left.arrangedSubviews.last!)
        left.addArrangedSubview(label("01   打开手机上的哔哩哔哩 App\n\n02   扫描右侧二维码，在手机上确认", size: 26, color: .lightGray))

        let panel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        panel.layer.cornerRadius = 36
        panel.clipsToBounds = true
        view.addSubview(panel)
        panel.snp.makeConstraints { make in
            make.trailing.equalTo(view.safeAreaLayoutGuide).offset(-55)
            make.centerY.equalToSuperview()
            make.width.equalTo(660)
            make.height.equalTo(770)
        }
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        panel.contentView.addSubview(stack)
        stack.snp.makeConstraints { make in make.edges.equalToSuperview().inset(40) }
        stack.addArrangedSubview(label("扫码登录", size: 34, weight: .semibold))
        let qrFrame = UIView()
        qrFrame.backgroundColor = .white
        qrFrame.layer.cornerRadius = 22
        qrFrame.addSubview(qrcodeImageView)
        qrcodeImageView.contentMode = .scaleAspectFit
        qrcodeImageView.accessibilityIdentifier = "living.qr"
        qrcodeImageView.accessibilityLabel = "哔哩哔哩登录二维码"
        qrcodeImageView.isAccessibilityElement = true
        qrcodeImageView.snp.makeConstraints { make in make.edges.equalToSuperview().inset(24) }
        qrFrame.addSubview(spinner)
        spinner.color = .darkGray
        spinner.snp.makeConstraints { make in make.center.equalToSuperview() }
        stack.addArrangedSubview(qrFrame)
        qrFrame.snp.makeConstraints { make in make.width.height.equalTo(380) }
        statusLabel.font = .systemFont(ofSize: 21)
        statusLabel.textColor = .lightGray
        statusLabel.numberOfLines = 2
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "living.login.status"
        stack.addArrangedSubview(statusLabel)
        statusLabel.snp.makeConstraints { make in make.height.equalTo(55); make.width.equalToSuperview() }
        var config = UIButton.Configuration.plain()
        config.title = "刷新二维码"
        config.image = UIImage(systemName: "arrow.clockwise")
        config.imagePadding = 10
        let refresh = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.initValidation() })
        refresh.accessibilityIdentifier = "living.qr.refresh"
        stack.addArrangedSubview(refresh)
        let browse = UIButton(type: .system)
        browse.setTitle("先逛逛", for: .normal)
        browse.addAction(UIAction { _ in AppDelegate.shared.showTabBar() }, for: .primaryActionTriggered)
        browse.accessibilityIdentifier = "living.browse"
        stack.addArrangedSubview(browse)
    }
}

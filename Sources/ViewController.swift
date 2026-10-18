import UIKit
import WebKit
import CoreLocation
import UserNotifications

class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, CLLocationManagerDelegate, WKScriptMessageHandler {

    private var webView: WKWebView!
    private let locationManager = CLLocationManager()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let refreshControl = UIRefreshControl()

    private let targetURL = URL(string: "https://detector-aero.ru/")!

    // MARK: - Error View Components
    private lazy var errorContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor(red: 0.07, green: 0.10, blue: 0.12, alpha: 1.0)
        view.isHidden = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let iconLabel = UILabel()
        iconLabel.text = "📡"
        iconLabel.font = .systemFont(ofSize: 54)

        let titleLabel = UILabel()
        titleLabel.text = "Ошибка подключения"
        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 20)
        titleLabel.textAlignment = .center

        let messageLabel = UILabel()
        messageLabel.text = "Проверьте интернет-соединение и повторите попытку"
        messageLabel.textColor = UIColor(white: 0.8, alpha: 1.0)
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let retryButton = UIButton(type: .system)
        retryButton.backgroundColor = UIColor(red: 0.18, green: 0.55, blue: 0.42, alpha: 1.0)
        retryButton.layer.cornerRadius = 10
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.filled()
            config.title = "Повторить"
            config.baseBackgroundColor = UIColor(red: 0.18, green: 0.55, blue: 0.42, alpha: 1.0)
            config.baseForegroundColor = .white
            config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 32, bottom: 12, trailing: 32)
            retryButton.configuration = config
        } else {
            retryButton.setTitle("Повторить", for: .normal)
            retryButton.setTitleColor(.white, for: .normal)
            retryButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
            retryButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 32, bottom: 12, right: 32)
        }
        retryButton.addTarget(self, action: #selector(didTapRetry), for: .touchUpInside)

        stack.addArrangedSubview(iconLabel)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(retryButton)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])

        return view
    }()

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor(red: 0.07, green: 0.10, blue: 0.12, alpha: 1.0)

        // Request Location Authorization for user GPS marker
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()

        setupWebView()
        setupProgressView()
        setupErrorView()

        loadRadar()
    }

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        if #available(iOS 15.4, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // User Content Controller for receiving alerts from Web and injecting notification bridge
        let contentController = WKUserContentController()
        contentController.add(self, name: "aeroAlert")

        let jsBridge = """
        (function() {
            // Hook standard Notification API
            window.Notification = function(title, options) {
                try {
                    window.webkit.messageHandlers.aeroAlert.postMessage({
                        title: title || '⚠️ Детектор АЭРО',
                        body: options?.body || 'Внимание: изменение воздушной обстановки!'
                    });
                } catch(e) {}
            };
            window.Notification.permission = 'granted';
            window.Notification.requestPermission = function(cb) {
                if (cb) cb('granted');
                return Promise.resolve('granted');
            };

            // DOM Observer for danger alerts, air alarms, UAV alerts
            const seenAlerts = new Set();
            const alertObserver = new MutationObserver(function() {
                const selectors = [
                    '.public-event-toast',
                    '.public-notification',
                    '[role="alert"]',
                    '.public-mobile-status',
                    '.toast',
                    '.alert'
                ];
                document.querySelectorAll(selectors.join(',')).forEach(function(el) {
                    const text = (el.innerText || el.textContent || '').trim();
                    if (text && text.length > 5 && !seenAlerts.has(text)) {
                        const lower = text.toLowerCase();
                        if (lower.includes('бпла') || lower.includes('ракет') || lower.includes('опасност') || 
                            lower.includes('тревог') || lower.includes('внимание') || lower.includes('пво') || lower.includes('отбой')) {
                            seenAlerts.add(text);
                            try {
                                window.webkit.messageHandlers.aeroAlert.postMessage({
                                    title: '🚨 Детектор АЭРО: Тревога!',
                                    body: text
                                });
                            } catch(e) {}
                        }
                    }
                });
            });
            alertObserver.observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
        let userScript = WKUserScript(source: jsBridge, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        contentController.addUserScript(userScript)
        configuration.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.07, green: 0.10, blue: 0.12, alpha: 1.0)
        webView.scrollView.backgroundColor = webView.backgroundColor

        // Pull to refresh
        refreshControl.addTarget(self, action: #selector(didPullToRefresh), for: .valueChanged)
        refreshControl.tintColor = .white
        webView.scrollView.addSubview(refreshControl)

        // Observe loading progress
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)

        view.addSubview(webView)

        // Fullscreen edge-to-edge layout
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupProgressView() {
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.tintColor = UIColor(red: 0.20, green: 0.70, blue: 0.50, alpha: 1.0)
        progressView.trackTintColor = .clear
        view.addSubview(progressView)

        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2.5)
        ])
    }

    private func setupErrorView() {
        view.addSubview(errorContainerView)
        NSLayoutConstraint.activate([
            errorContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            errorContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func loadRadar() {
        errorContainerView.isHidden = true
        let request = URLRequest(url: targetURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        webView.load(request)
    }

    @objc private func didPullToRefresh() {
        webView.reload()
    }

    @objc private func didTapRetry() {
        loadRadar()
    }

    // MARK: - WKScriptMessageHandler (Receiving alerts from JavaScript)
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "aeroAlert",
              let dict = message.body as? [String: Any] else { return }

        let title = (dict["title"] as? String) ?? "🚨 Детектор АЭРО: Тревога!"
        let body = (dict["body"] as? String) ?? "Внимание: воздушная опасность!"

        // Schedule immediate local notification
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        content.badge = 1

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)

        // Haptic notification
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }

    // MARK: - KVO Progress
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey : Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == #keyPath(WKWebView.estimatedProgress) {
            let progress = Float(webView.estimatedProgress)
            progressView.setProgress(progress, animated: true)
            if progress >= 1.0 {
                UIView.animate(withDuration: 0.3, delay: 0.2, options: .curveEaseOut, animations: {
                    self.progressView.alpha = 0.0
                }) { _ in
                    self.progressView.setProgress(0.0, animated: false)
                }
            } else {
                progressView.alpha = 1.0
            }
        }
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        errorContainerView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        let nsError = error as NSError
        if nsError.code != NSURLErrorCancelled {
            errorContainerView.isHidden = false
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        let nsError = error as NSError
        if nsError.code != NSURLErrorCancelled {
            errorContainerView.isHidden = false
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Open external links (such as Telegram / external websites) in Safari
        if let host = url.host?.lowercased() {
            if host.contains("detector-aero.ru") || host.contains("yandex") || host.contains("arcgisonline.com") {
                decisionHandler(.allow)
                return
            }
        }

        if navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate (Permissions)
    @available(iOS 15.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }

    @available(iOS 15.0, *)
    func webView(
        _ webView: WKWebView,
        requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "aeroAlert")
    }
}

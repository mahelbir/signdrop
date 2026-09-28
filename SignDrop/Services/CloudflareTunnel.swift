import Foundation

extension CommandLineTunnel {
    static func cloudflare() -> CommandLineTunnel {
        CommandLineTunnel(
            name: "Cloudflare Tunnel",
            executable: "cloudflared",
            brewPackage: "cloudflared",
            installPage: URL(string: "https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/#macos")!,
            arguments: { port in ["tunnel", "--no-autoupdate", "--config", "/dev/null", "--grace-period", "1s", "--url", "http://127.0.0.1:\(port)"] },
            publicURLPattern: "https://[a-z0-9]+(-[a-z0-9]+)+\\.trycloudflare\\.com",
            hasFreshHostname: true
        )
    }
}

// yoyo-server: the Mac's screen service on its own, without the menu bar app (mac/README.md「Embedding the service」).
//
//   yoyo-server --socket <path> [--remote <home>] [--port <n> --token-file <f>] …   (ServiceHost's command line)
//
// No service address is built in: the link's relays (YOYO_LINK_RELAYS), a signaling server (YOYO_SIGNAL_URL) and a
// web app for browser pairing (YOYO_WEBAPP_URL) are whatever its environment names, else none.
import YoyoServer

ServiceHost.main(options: .init(allowsRemote: true))

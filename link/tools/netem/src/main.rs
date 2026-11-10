//! uu-link-netem: a UDP proxy that impairs what it forwards, to try uu Link on a bad network from one machine.
//!
//!     uu-link-netem --listen 127.0.0.1:47900 --to 127.0.0.1:47820 --profile 5g
//!
//! Clients send to `--listen`; each client address gets its own upstream socket towards `--to`, so replies find
//! their way back. Both directions get the same impairment, each with its own state: one-way delay + jitter (order
//! kept unless `--reorder`), random loss, burst loss, reordering, a rate cap with a bounded queue (tail drop), and
//! handovers (a blackout, then extra delay). Profiles (docs/LINK.md「Testing」) set all of these; flags after
//! `--profile` override single values. Deterministic per `--seed`.

use std::{
    cmp::Reverse,
    collections::{BinaryHeap, HashMap},
    net::SocketAddr,
    process::exit,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use rand::{Rng, SeedableRng, rngs::StdRng};
use tokio::{
    net::UdpSocket,
    sync::{Mutex, mpsc},
    time::Instant,
};

#[derive(Debug, Clone)]
struct Profile {
    delay_ms: f64,
    jitter_ms: f64,
    loss_pct: f64,
    burst_pct: f64,
    burst_min: u32,
    burst_max: u32,
    reorder_pct: f64,
    /// 0 = no cap
    rate_mbps: f64,
    queue_ms: f64,
    /// 0 = no handovers
    handover_every_s: f64,
    blackout_ms: f64,
    handover_extra_ms: f64,
    handover_extra_for_s: f64,
}

impl Profile {
    fn none() -> Self {
        Profile {
            delay_ms: 0.0,
            jitter_ms: 0.0,
            loss_pct: 0.0,
            burst_pct: 0.0,
            burst_min: 5,
            burst_max: 20,
            reorder_pct: 0.0,
            rate_mbps: 0.0,
            queue_ms: 60.0,
            handover_every_s: 0.0,
            blackout_ms: 300.0,
            handover_extra_ms: 20.0,
            handover_extra_for_s: 3.0,
        }
    }

    fn named(name: &str) -> Option<Self> {
        let p = Profile::none();
        Some(match name {
            "none" => p,
            "lan" => Profile { delay_ms: 2.0, ..p },
            "5g" => Profile {
                delay_ms: 35.0,
                jitter_ms: 15.0,
                loss_pct: 1.0,
                burst_pct: 0.2,
                burst_min: 5,
                burst_max: 20,
                rate_mbps: 30.0,
                queue_ms: 60.0,
                ..p
            },
            "bad" => Profile {
                delay_ms: 60.0,
                jitter_ms: 40.0,
                loss_pct: 5.0,
                burst_pct: 0.5,
                burst_min: 30,
                burst_max: 30,
                rate_mbps: 10.0,
                queue_ms: 100.0,
                ..p
            },
            "handover" => Profile {
                delay_ms: 35.0,
                jitter_ms: 5.0,
                handover_every_s: 10.0,
                blackout_ms: 300.0,
                handover_extra_ms: 20.0,
                handover_extra_for_s: 3.0,
                ..p
            },
            _ => return None,
        })
    }
}

#[derive(Default)]
struct Counters {
    forwarded: AtomicU64,
    lost_random: AtomicU64,
    lost_burst: AtomicU64,
    lost_queue: AtomicU64,
    lost_blackout: AtomicU64,
    reordered: AtomicU64,
}

/// One direction's impairment state.
struct Shaper {
    p: Profile,
    rng: StdRng,
    burst_left: u32,
    /// when the bottleneck is free again (rate cap)
    link_free: Instant,
    /// the last delivery time (to keep order under jitter)
    last_delivery: Instant,
    start: Instant,
    counters: Arc<Counters>,
}

enum Verdict {
    Drop,
    Deliver(Instant),
}

impl Shaper {
    fn new(p: Profile, seed: u64, counters: Arc<Counters>) -> Self {
        let now = Instant::now();
        Shaper {
            p,
            rng: StdRng::seed_from_u64(seed),
            burst_left: 0,
            link_free: now,
            last_delivery: now,
            start: now,
            counters,
        }
    }

    fn judge(&mut self, len: usize, now: Instant) -> Verdict {
        let c = &self.counters;
        // handovers: a blackout at every period's start, extra delay right after it
        let mut extra = 0.0;
        if self.p.handover_every_s > 0.0 {
            let t = now.duration_since(self.start).as_secs_f64();
            let period = self.p.handover_every_s;
            let into = if t < period { f64::INFINITY } else { t % period };
            if into * 1e3 < self.p.blackout_ms {
                c.lost_blackout.fetch_add(1, Ordering::Relaxed);
                return Verdict::Drop;
            }
            if into < self.p.blackout_ms / 1e3 + self.p.handover_extra_for_s {
                extra = self.p.handover_extra_ms;
            }
        }
        if self.burst_left > 0 {
            self.burst_left -= 1;
            c.lost_burst.fetch_add(1, Ordering::Relaxed);
            return Verdict::Drop;
        }
        if self.p.burst_pct > 0.0 && self.rng.random::<f64>() * 100.0 < self.p.burst_pct {
            self.burst_left = self.rng.random_range(self.p.burst_min..=self.p.burst_max.max(self.p.burst_min)) - 1;
            c.lost_burst.fetch_add(1, Ordering::Relaxed);
            return Verdict::Drop;
        }
        if self.p.loss_pct > 0.0 && self.rng.random::<f64>() * 100.0 < self.p.loss_pct {
            c.lost_random.fetch_add(1, Ordering::Relaxed);
            return Verdict::Drop;
        }
        // the bottleneck: serialization at the rate cap, tail drop beyond the queue
        let mut leave = now;
        if self.p.rate_mbps > 0.0 {
            let start = self.link_free.max(now);
            if start.duration_since(now).as_secs_f64() * 1e3 > self.p.queue_ms {
                c.lost_queue.fetch_add(1, Ordering::Relaxed);
                return Verdict::Drop;
            }
            let tx = Duration::from_secs_f64(len as f64 * 8.0 / (self.p.rate_mbps * 1e6));
            self.link_free = start + tx;
            leave = self.link_free;
        }
        let jitter = if self.p.jitter_ms > 0.0 { self.rng.random::<f64>() * self.p.jitter_ms } else { 0.0 };
        let mut at = leave + Duration::from_secs_f64((self.p.delay_ms + jitter + extra) / 1e3);
        if self.p.reorder_pct > 0.0 && self.rng.random::<f64>() * 100.0 < self.p.reorder_pct {
            // this one overtakes or falls behind its neighbours
            c.reordered.fetch_add(1, Ordering::Relaxed);
        } else {
            at = at.max(self.last_delivery);
            self.last_delivery = at;
        }
        c.forwarded.fetch_add(1, Ordering::Relaxed);
        Verdict::Deliver(at)
    }
}

struct Packet {
    at: Instant,
    seq: u64,
    data: Vec<u8>,
}

impl PartialEq for Packet {
    fn eq(&self, o: &Self) -> bool {
        (self.at, self.seq) == (o.at, o.seq)
    }
}
impl Eq for Packet {}
impl PartialOrd for Packet {
    fn partial_cmp(&self, o: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for Packet {
    fn cmp(&self, o: &Self) -> std::cmp::Ordering {
        (self.at, self.seq).cmp(&(o.at, o.seq))
    }
}

/// A direction: packets in through `tx`, out through `send` when their time comes.
fn pipe<F>(mut shaper: Shaper, send: F) -> mpsc::UnboundedSender<Vec<u8>>
where
    F: Fn(Vec<u8>) + Send + 'static,
{
    let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    tokio::spawn(async move {
        let mut heap: BinaryHeap<Reverse<Packet>> = BinaryHeap::new();
        let mut seq = 0u64;
        loop {
            let next = heap.peek().map(|Reverse(p)| p.at);
            tokio::select! {
                m = rx.recv() => {
                    let Some(data) = m else { break };
                    let now = Instant::now();
                    if let Verdict::Deliver(at) = shaper.judge(data.len() + 28, now) {
                        seq += 1;
                        heap.push(Reverse(Packet { at, seq, data }));
                    }
                }
                _ = async { tokio::time::sleep_until(next.unwrap()).await }, if next.is_some() => {
                    let now = Instant::now();
                    while heap.peek().is_some_and(|Reverse(p)| p.at <= now) {
                        let Reverse(p) = heap.pop().unwrap();
                        send(p.data);
                    }
                }
            }
        }
    });
    tx
}

fn usage() -> ! {
    eprintln!(
        "usage: uu-link-netem --listen <ip:port> --to <ip:port> [--profile lan|5g|bad|handover|none]\n\
         \x20      [--delay ms] [--jitter ms] [--loss %] [--burst %] [--burst-min n] [--burst-max n] [--reorder %]\n\
         \x20      [--rate mbps] [--queue ms] [--handover-every s] [--blackout ms] [--handover-extra ms]\n\
         \x20      [--seed n] [--quiet]"
    );
    exit(2)
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
#[allow(clippy::map_entry)] // a new flow awaits while it is set up
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut listen: Option<SocketAddr> = None;
    let mut to: Option<SocketAddr> = None;
    let mut p = Profile::none();
    let mut seed = 1u64;
    let mut quiet = false;
    let mut name = "none".to_string();
    let mut i = 0;
    while i < args.len() {
        let flag = args[i].as_str();
        let mut val = || {
            i += 1;
            args.get(i).cloned().unwrap_or_else(|| usage())
        };
        let num = |s: String| s.parse::<f64>().unwrap_or_else(|_| usage());
        match flag {
            "--listen" => listen = Some(val().parse().unwrap_or_else(|_| usage())),
            "--to" => to = Some(val().parse().unwrap_or_else(|_| usage())),
            "--profile" => {
                name = val();
                p = Profile::named(&name).unwrap_or_else(|| usage());
            }
            "--delay" => p.delay_ms = num(val()),
            "--jitter" => p.jitter_ms = num(val()),
            "--loss" => p.loss_pct = num(val()),
            "--burst" => p.burst_pct = num(val()),
            "--burst-min" => p.burst_min = num(val()) as u32,
            "--burst-max" => p.burst_max = num(val()) as u32,
            "--reorder" => p.reorder_pct = num(val()),
            "--rate" => p.rate_mbps = num(val()),
            "--queue" => p.queue_ms = num(val()),
            "--handover-every" => p.handover_every_s = num(val()),
            "--blackout" => p.blackout_ms = num(val()),
            "--handover-extra" => p.handover_extra_ms = num(val()),
            "--seed" => seed = num(val()) as u64,
            "--quiet" => quiet = true,
            _ => usage(),
        }
        i += 1;
    }
    let (Some(listen), Some(to)) = (listen, to) else { usage() };
    let front = Arc::new(UdpSocket::bind(listen).await.unwrap_or_else(|e| {
        eprintln!("netem: bind {listen}: {e}");
        exit(1)
    }));
    eprintln!("netem: {} → {to}, profile {name}: {p:?}", front.local_addr().unwrap());

    let up = Arc::new(Counters::default());
    let down = Arc::new(Counters::default());
    if !quiet {
        let (up, down) = (up.clone(), down.clone());
        tokio::spawn(async move {
            let mut t = tokio::time::interval(Duration::from_secs(5));
            t.tick().await;
            loop {
                t.tick().await;
                for (dir, c) in [("up", &up), ("down", &down)] {
                    eprintln!(
                        "netem {dir}: fwd {} lost random {} burst {} queue {} blackout {} reordered {}",
                        c.forwarded.load(Ordering::Relaxed),
                        c.lost_random.load(Ordering::Relaxed),
                        c.lost_burst.load(Ordering::Relaxed),
                        c.lost_queue.load(Ordering::Relaxed),
                        c.lost_blackout.load(Ordering::Relaxed),
                        c.reordered.load(Ordering::Relaxed),
                    );
                }
            }
        });
    }

    struct Flow {
        up: mpsc::UnboundedSender<Vec<u8>>,
    }
    let flows: Arc<Mutex<HashMap<SocketAddr, Flow>>> = Arc::default();
    let mut n_flows = 0u64;
    let mut buf = vec![0u8; 65536];
    loop {
        let (n, client) = match front.recv_from(&mut buf).await {
            Ok(x) => x,
            Err(e) => {
                eprintln!("netem: recv: {e}");
                continue;
            }
        };
        let mut map = flows.lock().await;
        if !map.contains_key(&client) {
            n_flows += 1;
            let bind: SocketAddr = if to.is_ipv4() { "0.0.0.0:0".parse().unwrap() } else { "[::]:0".parse().unwrap() };
            let sock = Arc::new(UdpSocket::bind(bind).await.expect("upstream socket"));
            sock.connect(to).await.expect("connect upstream");
            let s2 = sock.clone();
            let up_tx = pipe(Shaper::new(p.clone(), seed ^ (n_flows << 1), up.clone()), move |d| {
                let _ = s2.try_send(&d);
            });
            let f2 = front.clone();
            let down_tx = pipe(Shaper::new(p.clone(), seed ^ (n_flows << 1 | 1), down.clone()), move |d| {
                let _ = f2.try_send_to(&d, client);
            });
            tokio::spawn(async move {
                let mut b = vec![0u8; 65536];
                while let Ok(n) = sock.recv(&mut b).await {
                    if down_tx.send(b[..n].to_vec()).is_err() {
                        break;
                    }
                }
            });
            if !quiet {
                eprintln!("netem: new flow {client}");
            }
            map.insert(client, Flow { up: up_tx });
        }
        let _ = map[&client].up.send(buf[..n].to_vec());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(p: Profile, n: usize, gap: Duration) -> (Arc<Counters>, Vec<Duration>) {
        let c = Arc::new(Counters::default());
        let mut s = Shaper::new(p, 7, c.clone());
        let t0 = Instant::now();
        let mut delays = Vec::new();
        for i in 0..n {
            let now = t0 + gap * i as u32;
            if let Verdict::Deliver(at) = s.judge(1200, now) {
                delays.push(at.duration_since(now));
            }
        }
        (c, delays)
    }

    #[test]
    fn five_g_loses_about_what_it_says() {
        let (c, delays) = run(Profile::named("5g").unwrap(), 100_000, Duration::from_micros(1000));
        let lost = c.lost_random.load(Ordering::Relaxed) + c.lost_burst.load(Ordering::Relaxed);
        let pct = lost as f64 / 1000.0;
        // 1 % random + 0.2 % × ~12.5 packets per burst ≈ 3.5 %
        assert!((2.0..5.0).contains(&pct), "loss {pct} %");
        assert_eq!(c.lost_queue.load(Ordering::Relaxed), 0, "9.6 Mbps fits the 30 Mbps cap");
        let min = delays.iter().min().unwrap().as_secs_f64() * 1e3;
        let max = delays.iter().max().unwrap().as_secs_f64() * 1e3;
        assert!(min >= 35.0 && max < 35.0 + 15.0 + 2.0, "{min} … {max}");
    }

    #[test]
    fn rate_cap_queues_then_drops() {
        let p = Profile { rate_mbps: 8.0, queue_ms: 50.0, ..Profile::none() };
        // 1200 B every 0.5 ms = 19.2 Mbps into 8 Mbps: the queue fills to 50 ms, then the tail drops
        let (c, delays) = run(p, 4000, Duration::from_micros(500));
        assert!(c.lost_queue.load(Ordering::Relaxed) > 1500);
        let max = delays.iter().max().unwrap().as_secs_f64() * 1e3;
        assert!(max <= 52.0, "queue delay {max} ms");
    }

    #[test]
    fn handover_blacks_out() {
        let p = Profile::named("handover").unwrap();
        let (c, _) = run(p, 25_000, Duration::from_millis(1));
        // two handovers in 25 s (at 10 s and 20 s), 300 ms each at 1 packet / ms
        let b = c.lost_blackout.load(Ordering::Relaxed);
        assert!((590..=610).contains(&b), "{b}");
    }
}

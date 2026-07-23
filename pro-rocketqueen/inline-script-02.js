
        // ─── Rocket Queen LIVE: прямой read-only источник ─────────────────────────
        const GATEWAY_URL = 'https://crash-gateway-grm-cr.100hp.app/state';
        const CUSTOMER_ID = '077dee8d-c923-4c02-9bee-757573662e69';
        const SESSION_SEED = '1d19cd61-f93c-4056-9b3a-2a25481a6af8';
        const RQ_LIVE_KEY = 'lumorax_rocketqueen_direct_v1';
        const RQ_ROUND_KEY = 'lumorax_rocketqueen_round_v1';
        const RQ_SESSION_KEY = 'lumorax_rocketqueen_session_v1';
        const FETCH_TIMEOUT_MS = 8000;
        const GATEWAY_POLL_MS = 4000;
        // ─────────────────────────────────────────────────────────────────────────

        /* ── PARTICLES ── */
        function createParticles() {
            const c = document.getElementById('particles');
            for (let i = 0; i < 60; i++) {
                const p = document.createElement('div'); p.className = 'ptcl';
                const sz = 1 + Math.random() * 3;
                p.style.cssText = `left:${Math.random() * 100}%;width:${sz}px;height:${sz}px;--dur:${6 + Math.random() * 14}s;--op:${0.2 + Math.random() * 0.5};animation-delay:${Math.random() * 15}s`;
                c.appendChild(p);
            }
        }

        /* ── WAVE CANVAS ── */
        const canvas = document.getElementById('waveCanvas');
        const ctx = canvas.getContext('2d');
        const CX = 110, CY = 110, R = 88;
        let wavePhase = 0, waveAngle = 0, waveColorHue = 20;

        const particles2 = Array.from({ length: 180 }, (_, i) => ({
            angle: (i / 180) * Math.PI * 2, offset: Math.random() * Math.PI * 2,
            speed: 0.002 + Math.random() * 0.004, size: 0.6 + Math.random() * 1.6,
            baseR: R + (Math.random() - 0.5) * 18, opacity: 0.3 + Math.random() * 0.6,
            layer: Math.floor(Math.random() * 3)
        }));

        function drawFrame() {
            ctx.clearRect(0, 0, 220, 220); wavePhase += 0.02; waveAngle += 0.006;
            const grd = ctx.createRadialGradient(CX, CY, R - 30, CX, CY, R + 30);
            grd.addColorStop(0, `hsla(${waveColorHue},100%,55%,0)`);
            grd.addColorStop(0.3, `hsla(${waveColorHue},100%,55%,0.1)`);
            grd.addColorStop(0.7, `hsla(${waveColorHue + 30},100%,65%,0.07)`);
            grd.addColorStop(1, `hsla(${waveColorHue},100%,55%,0)`);
            ctx.beginPath(); ctx.arc(CX, CY, R + 30, 0, Math.PI * 2); ctx.fillStyle = grd; ctx.fill();
            for (let i = 0; i < 360; i++) {
                const a = (i / 360) * Math.PI * 2;
                const r = R + Math.sin(a * 5 + wavePhase) * 9 + Math.sin(a * 3 - wavePhase * 1.1) * 6 + Math.cos(a * 9 + wavePhase * 0.7) * 3;
                const x = CX + Math.cos(a) * r, y = CY + Math.sin(a) * r;
                const hue = waveColorHue + (i / 360) * 60 + waveAngle * 20;
                ctx.beginPath(); ctx.arc(x, y, 0.8 + (Math.sin(a * 4 + wavePhase) + 1) * 0.8, 0, Math.PI * 2);
                ctx.fillStyle = `hsla(${hue},100%,65%,${0.5 + Math.sin(a * 3 + wavePhase) * 0.3})`; ctx.fill();
            }
            particles2.forEach(p => {
                p.angle += p.speed;
                const r = p.baseR + Math.sin(p.angle * 4 + wavePhase + p.offset) * 10;
                ctx.beginPath(); ctx.arc(CX + Math.cos(p.angle + waveAngle * 0.5) * r, CY + Math.sin(p.angle + waveAngle * 0.5) * r, p.size, 0, Math.PI * 2);
                ctx.fillStyle = `hsla(${waveColorHue + p.layer * 35 + (p.angle / (Math.PI * 2)) * 50},100%,70%,${p.opacity * (0.5 + Math.sin(wavePhase + p.offset) * 0.35)})`; ctx.fill();
            });
            const lx1 = CX + Math.cos(waveAngle) * (R - 20), ly1 = CY + Math.sin(waveAngle) * (R - 20);
            const lx2 = CX + Math.cos(waveAngle) * (R + 20), ly2 = CY + Math.sin(waveAngle) * (R + 20);
            const lg = ctx.createLinearGradient(lx1, ly1, lx2, ly2);
            lg.addColorStop(0, `hsla(${waveColorHue + 40},100%,80%,0)`);
            lg.addColorStop(0.5, `hsla(${waveColorHue + 40},100%,95%,0.9)`);
            lg.addColorStop(1, `hsla(${waveColorHue + 40},100%,80%,0)`);
            ctx.beginPath(); ctx.moveTo(lx1, ly1); ctx.lineTo(lx2, ly2);
            ctx.strokeStyle = lg; ctx.lineWidth = 2; ctx.stroke();
            requestAnimationFrame(drawFrame);
        }
        function setWaveColor(m) {
            const map = { orange: 20, green: 130, red: 0, gold: 45, cyan: 185, pink: 320, blue: 210 };
            waveColorHue = map[m] ?? 20;
        }
        requestAnimationFrame(drawFrame);

        /* ── UI ── */
        function setWaitMode() {
            const el = document.getElementById('multiplierText');
            el.textContent = 'SCANNING'; el.className = 'wait-mode'; el.style.cssText = '';
            const ci = document.getElementById('circleInner');
            ci.style.borderColor = '#ff5500';
            ci.style.boxShadow = 'inset 0 0 25px rgba(255,80,0,0.2),0 0 0 4px rgba(255,80,0,0.15),0 0 30px rgba(255,80,0,0.2)';
        }
        function setPredictionMode(val, color) {
            const el = document.getElementById('multiplierText');
            el.textContent = val.toFixed(2) + 'X'; el.className = '';
            el.style.fontSize = val >= 10 ? '1.5rem' : '1.9rem';
            el.style.color = color.text; el.style.textShadow = color.shadow;
            el.style.fontFamily = "'Orbitron',monospace";
        }
        function setResultMode(success) {
            const el = document.getElementById('multiplierText'); el.className = '';
            el.style.fontFamily = "'Rajdhani',sans-serif";
            if (success) {
                el.textContent = '✅ WIN'; el.style.fontSize = '1.5rem'; el.style.color = '#00ff88';
                el.style.textShadow = '0 0 15px rgba(0,255,136,0.9)';
                document.getElementById('circleInner').style.borderColor = '#00ff88';
                document.getElementById('circleInner').style.boxShadow = 'inset 0 0 25px rgba(0,255,136,0.25),0 0 0 4px rgba(0,255,136,0.3),0 0 40px rgba(0,255,136,0.25)';
            } else {
                el.textContent = '❌ MISS'; el.style.fontSize = '1.5rem'; el.style.color = '#ff3333';
                el.style.textShadow = '0 0 15px rgba(255,50,50,0.9)';
                document.getElementById('circleInner').style.borderColor = '#ff2222';
                document.getElementById('circleInner').style.boxShadow = 'inset 0 0 25px rgba(255,0,0,0.25),0 0 0 4px rgba(255,0,0,0.3),0 0 40px rgba(255,0,0,0.2)';
            }
        }
        function hideAllIndicators() { ['waitGameIndicator', 'playIndicator', 'validationIndicator'].forEach(id => document.getElementById(id).style.display = 'none'); }
        function showIndicator(id) { hideAllIndicators(); document.getElementById(id).style.display = 'flex'; }
        function setStatus(html) { document.getElementById('statusIndicator').innerHTML = html; }
        function updateRoundDots(n, ok = null) {
            document.getElementById('roundsLabel').textContent = `TOUR ${n} / 3`;
            for (let i = 1; i <= 3; i++) {
                const d = document.getElementById(`dot${i}`); d.className = 'round-dot';
                if (i < n) d.classList.add('active');
                else if (i === n) { if (ok === true) d.classList.add('success'); else if (ok === false) d.classList.add('fail'); else d.classList.add('active'); }
            }
        }

        /* ── Локальные /coefficients, /check, /market, /predict ── */
        function readRocketHistory() {
            try {
                const value = JSON.parse(localStorage.getItem(RQ_LIVE_KEY) || '[]');
                return Array.isArray(value) ? value.filter(item => item && Number.isFinite(Number(item.coef))).slice(-200) : [];
            } catch (_error) { return []; }
        }
        let rocketHistory = readRocketHistory();
        let lastRocketRoundKey = localStorage.getItem(RQ_ROUND_KEY) || '';
        let gatewayPollPromise = null;
        let gatewayOnline = false;
        let gatewayErrors = 0;
        let rocketSessionId = localStorage.getItem(RQ_SESSION_KEY) || SESSION_SEED || createRocketSessionId();

        function createRocketSessionId() {
            if (globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function') return globalThis.crypto.randomUUID();
            return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, character => {
                const random = Math.random() * 16 | 0;
                return (character === 'x' ? random : (random & 3 | 8)).toString(16);
            });
        }
        function saveRocketSession(sessionId) {
            rocketSessionId = String(sessionId || '').trim() || createRocketSessionId();
            localStorage.setItem(RQ_SESSION_KEY, rocketSessionId);
            gatewayErrors = 0;
            return rocketSessionId;
        }
        function rotateRocketSession() { return saveRocketSession(createRocketSessionId()); }
        function rocketGatewayHeaders() {
            return { 'customer-id': CUSTOMER_ID, 'session-id': rocketSessionId, 'accept': 'application/json' };
        }
        window.setRocketQueenSession = saveRocketSession;

        document.getElementById('rqSessionButton').addEventListener('click', () => {
            const entered = prompt('Если автоматическое подключение не сработало, вставьте новый session-id Rocket Queen:', rocketSessionId);
            if (entered && /^[0-9a-f-]{20,}$/i.test(entered.trim())) {
                saveRocketSession(entered.trim());
                setStatus('<i class="fas fa-sync-alt" style="margin-right:8px;color:#ff8800"></i> Новый session-id сохранён, переподключение...');
                pollRocketGateway().catch(() => {});
            }
        });

        function rqClamp(value, min, max) { return Math.max(min, Math.min(max, value)); }
        function rqAverage(values) { return values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : 0; }
        function normalizeRocketCoef(value) {
            if (value == null || value === '') return null;
            const number = Number(typeof value === 'string' ? value.toLowerCase().replace('x', '').replace(',', '.').trim() : value);
            if (!Number.isFinite(number) || number < 1) return null;
            return Number((number === 1 ? 1.01 : number).toFixed(2));
        }
        function parseRocketRound(data) {
            const config = data && typeof data.roundConfig === 'object' ? data.roundConfig : {};
            const raw = Array.isArray(data && data.stopCoefficients) ? data.stopCoefficients[0] : null;
            const coef = normalizeRocketCoef(raw);
            if (coef == null) return null;
            const id = config.id || data.roundId || data.id || data.currentRoundId || '';
            const timestamp = data.stateChangedAt || data.currentTime || data.updatedAt || '';
            const key = id ? 'id:' + String(id) : (timestamp ? 'time:' + String(timestamp) + ':' + coef.toFixed(2) : 'coef:' + coef.toFixed(2));
            return { id: String(id || key), coef, timestamp: String(timestamp || new Date().toISOString()), key };
        }
        function saveRocketHistory() {
            localStorage.setItem(RQ_LIVE_KEY, JSON.stringify(rocketHistory.slice(-200)));
        }
        function acceptRocketRound(round) {
            if (!round || round.key === lastRocketRoundKey) return null;
            lastRocketRoundKey = round.key;
            localStorage.setItem(RQ_ROUND_KEY, round.key);
            rocketHistory.push({ id: round.id, coef: round.coef, timestamp: round.timestamp });
            if (rocketHistory.length > 200) rocketHistory = rocketHistory.slice(-200);
            saveRocketHistory();
            return round;
        }
        async function pollRocketGateway() {
            if (gatewayPollPromise) return gatewayPollPromise;
            gatewayPollPromise = (async () => {
                const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
                const timeout = controller ? setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS) : null;
                try {
                    const response = await fetch(GATEWAY_URL, {
                        headers: rocketGatewayHeaders(),
                        cache: 'no-store',
                        signal: controller ? controller.signal : undefined
                    });
                    if (!response.ok) throw new Error('Источник HTTP ' + response.status);
                    const round = parseRocketRound(await response.json());
                    gatewayOnline = true;
                    gatewayErrors = 0;
                    return acceptRocketRound(round);
                } catch (error) {
                    gatewayOnline = false;
                    gatewayErrors += 1;
                    if (gatewayErrors >= 3) rotateRocketSession();
                    throw error;
                } finally {
                    if (timeout) clearTimeout(timeout);
                }
            })();
            try { return await gatewayPollPromise; }
            finally { gatewayPollPromise = null; }
        }
        function analyzeRocketMarket() {
            const recent = rocketHistory.slice(-8).map(item => Number(item.coef));
            if (recent.length < 3) return { score: 50, level: 'warn', confidence: 50, reason: 'нужно больше завершённых раундов' };
            const lowCount = recent.filter(value => value < 1.5).length;
            const veryLow = recent.filter(value => value < 1.2).length;
            const trendUp = rqAverage(recent.slice(-4)) > rqAverage(recent.slice(0, 4));
            const score = Math.round(rqClamp(100 - (lowCount / recent.length) * 42 - veryLow * 8 + (trendUp ? 6 : -6), 0, 100));
            const level = score >= 70 ? 'safe' : (score >= 45 ? 'warn' : 'danger');
            const reason = lowCount >= 4 ? 'много низких коэффициентов' : (trendUp ? 'тренд растёт' : 'рынок нестабилен');
            return { score, level, confidence: Math.round(rqClamp(score, 40, 92)), reason };
        }
        function rocketCheck() {
            const market = analyzeRocketMarket();
            if (rocketHistory.length < 5) return { blocked: true, message: 'Сбор коэффициентов: ' + rocketHistory.length + '/5', market };
            const good = rocketHistory.slice(-5).filter(item => Number(item.coef) > 1.5).length;
            if (market.level === 'danger') return { blocked: true, message: 'Высокий риск: ' + market.reason, market };
            if (good < 3) return { blocked: true, message: 'Выше 1.50 только ' + good + '/5', market };
            return { blocked: false, message: 'Условия выполнены: ' + good + '/5 выше 1.50', market };
        }
        function rocketPrediction() {
            const check = rocketCheck();
            if (check.blocked) return { success: false, error: check.message };
            const values = rocketHistory.slice(-8).map(item => Number(item.coef));
            const lowRatio = values.filter(value => value < 1.5).length / values.length;
            const target = rqClamp(rqAverage(values) * 0.72 + check.market.score / 100 * 0.55 - lowRatio * 0.35, 1.20, 10.00);
            return {
                success: true,
                predicted_coef: Number(target.toFixed(2)),
                confidence: check.market.confidence,
                signal: check.market.level,
                bet_time: null,
                market_score: check.market.score,
                reason: check.message
            };
        }
        async function apGet(path) {
            try { await pollRocketGateway(); }
            catch (error) { if (!rocketHistory.length) throw error; }
            if (path.indexOf('/rocketqueen/coefficients') === 0) {
                const match = path.match(/[?&]limit=(\d+)/);
                const limit = match ? Math.max(1, Number(match[1])) : 20;
                return { success: true, online: gatewayOnline, data: rocketHistory.slice().reverse().slice(0, limit) };
            }
            if (path === '/rocketqueen/check') {
                const check = rocketCheck();
                return { success: true, blocked: check.blocked, message: check.message, market_score: check.market.score };
            }
            if (path === '/rocketqueen/market') {
                const market = analyzeRocketMarket();
                return { success: true, level: market.level, score: market.score, reason: market.reason, online: gatewayOnline };
            }
            if (path === '/rocketqueen/predict') {
                const prediction = rocketPrediction();
                if (prediction.success === false) throw new Error(prediction.error || 'Сигнал пока недоступен');
                return prediction;
            }
            throw new Error('Неизвестный локальный маршрут: ' + path);
        }
        window.RocketQueenLocalAPI = apGet;

        /* ── STATE ── */
        let isPredictionActive = false, currentPrediction = null, predictionTimeout = null;
        let validationInterval = null, validationRounds = 0;
        const MAX_ROUNDS = 3;
        let lastKnownCoefId = null, lastKnownCoefValue = null;

        /* ── INIT ── */
        createParticles();
        updateCurrentTime();
        setWaveColor('orange');
        setWaitMode();
        fetchData();
        pollRocketGateway().catch(() => {});
        setInterval(updateCurrentTime, 60000);
        setInterval(fetchData, 5000);
        setInterval(() => pollRocketGateway().catch(() => {}), GATEWAY_POLL_MS);

        function updateCurrentTime() {
            const n = new Date();
            document.getElementById('time').textContent =
                `${String(n.getHours()).padStart(2, '0')}:${String(n.getMinutes()).padStart(2, '0')}`;
        }

        function updateCountdown(s) {
            const el = document.getElementById('countdown');
            if (s <= 0) { el.textContent = ''; el.className = ''; return; }
            if (s <= 10) { el.textContent = '⚡ MISEZ MAINTENANT'; el.className = 'countdown-urgent'; }
            else {
                const m = Math.floor(s / 60), sec = s % 60;
                el.textContent = `MISE DANS ${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
                el.className = 'countdown-normal';
            }
        }

        async function fetchData() {
            if (isPredictionActive) return;
            try {
                const res = await apGet('/rocketqueen/coefficients?limit=3');
                setStatus(`<i class="fas fa-circle-notch fa-spin" style="margin-right:8px;color:#ff6600"></i> ${res.data.length}/3 signaux captés`);
                if (res.data.length >= 3) await startPrediction();
            } catch (e) {
                setStatus(`<i class="fas fa-exclamation-triangle" style="margin-right:8px;color:#ff4444"></i> Analyse — detection...`);
            }
        }

        async function startPrediction() {
            if (isPredictionActive) return;
            isPredictionActive = true; validationRounds = 0;

            try {
                // ── 1. /check : série de pertes ? (doc : appeler avant /predict) ──
                setStatus(`<i class="fas fa-circle-notch fa-spin" style="margin-right:8px;color:#ff6600"></i> Vérification du marché...`);
                const chk = await apGet('/rocketqueen/check');
                if (chk.blocked) {
                    setStatus(`<i class="fas fa-ban" style="margin-right:8px;color:#ff4444"></i> ${chk.message}`);
                    isPredictionActive = false; setWaitMode(); setWaveColor('orange'); return;
                }

                // ── 2. /market : conditions générales (doc : appeler avant /predict) ──
                const mkt = await apGet('/rocketqueen/market');
                if (mkt.level === 'danger') {
                    setStatus(`<i class="fas fa-exclamation-triangle" style="margin-right:8px;color:#ff4444"></i> Marché dangereux (score ${mkt.score}) — ${mkt.reason}`);
                    isPredictionActive = false; setWaitMode(); setWaveColor('orange'); return;
                }

                // ── 3. /predict : analyse ─────────────────────────────────────────
                const pred = await apGet('/rocketqueen/predict');
                const val = pred.predicted_coef, conf = pred.confidence, signal = pred.signal;

                // Confiance < 60 → peu fiable selon la doc
                if (conf < 60) {
                    setStatus(`<i class="fas fa-exclamation-circle" style="margin-right:8px"></i> Confiance insuffisante (${conf}%) — attente`);
                    isPredictionActive = false; setWaitMode(); setWaveColor('orange'); return;
                }
                // Signal danger → ne pas miser
                if (signal === 'danger') {
                    setStatus(`<i class="fas fa-exclamation-circle" style="margin-right:8px"></i> Signal danger — prédiction ignorée`);
                    isPredictionActive = false; setWaitMode(); setWaveColor('orange'); return;
                }

                document.getElementById('confidenceBadge').style.display = 'flex';
                document.getElementById('confidenceValue').textContent = conf;

                let color, waveMode;
                if (val > 8) { color = { text: '#FFD700', shadow: '0 0 18px rgba(255,215,0,0.9)' }; waveMode = 'gold'; }
                else if (val > 6) { color = { text: '#00FFFF', shadow: '0 0 14px rgba(0,255,255,0.8)' }; waveMode = 'cyan'; }
                else if (val > 4) { color = { text: '#ff69b4', shadow: '0 0 14px rgba(255,105,180,0.8)' }; waveMode = 'pink'; }
                else { color = { text: '#ff8800', shadow: '0 0 15px rgba(255,136,0,0.9)' }; waveMode = 'orange'; }
                setPredictionMode(val, color); setWaveColor(waveMode);
                currentPrediction = { value: val };

                const betTime = pred.bet_time;
                if (betTime) {
                    const [bh, bm] = betTime.split(':').map(Number);
                    const now = new Date(), est = new Date(now);
                    est.setHours(bh, bm, 0, 0);
                    if (est <= now) est.setDate(est.getDate() + 1);
                    document.getElementById('time').textContent = `${String(bh).padStart(2, '0')}:${String(bm).padStart(2, '0')}`;
                    setStatus(`<i class="fas fa-bolt" style="margin-right:8px;color:#ff8800"></i> Signal verrouillé : <strong style="color:#ffaa00">${val.toFixed(2)}X</strong>`);
                    startCountdownTimer(est);
                } else {
                    document.getElementById('time').textContent = '--:--';
                    setStatus(`<i class="fas fa-bolt" style="margin-right:8px;color:#ff8800"></i> Signal verrouillé : <strong style="color:#ffaa00">${val.toFixed(2)}X</strong>`);
                    await onBetTimeReached();
                }

            } catch (e) {
                setStatus(`<i class="fas fa-exclamation-triangle" style="margin-right:8px"></i> Erreur : ${e.message}`);
                isPredictionActive = false; setWaitMode(); setWaveColor('orange');
            }
        }

        function startCountdownTimer(target) {
            const tick = async () => {
                const diff = target - new Date();
                if (diff <= 0) { await onBetTimeReached(); return; }
                updateCountdown(Math.floor(diff / 1000));
                predictionTimeout = setTimeout(tick, 1000);
            }; tick();
        }

        async function onBetTimeReached() {
            updateCountdown(0);
            try {
                const res = await apGet('/rocketqueen/coefficients?limit=1');
                lastKnownCoefId = res.data[0].id ?? (res.data[0].coef + '_' + res.data[0].timestamp);
                lastKnownCoefValue = res.data[0].coef;
            } catch (e) { lastKnownCoefId = null; lastKnownCoefValue = null; }
            checkBeforeBetting();
        }

        function checkBeforeBetting() {
            showIndicator('waitGameIndicator');
            setStatus(`<i class="fas fa-radar" style="margin-right:8px"></i> Vérification état du jeu...`);
            let waited = 0;
            const poll = async () => {
                try {
                    const res = await apGet('/rocketqueen/coefficients?limit=1');
                    const lid = res.data[0].id ?? (res.data[0].coef + '_' + res.data[0].timestamp);
                    if (lastKnownCoefId === null || lid !== lastKnownCoefId) {
                        lastKnownCoefId = lid; lastKnownCoefValue = res.data[0].coef; showBetSignal(); return;
                    }
                } catch (e) { }
                waited += 3000;
                if (waited >= 60000) { showBetSignal(); return; }
                setTimeout(poll, 3000);
            }; setTimeout(poll, 3000);
        }

        function showBetSignal() {
            showIndicator('playIndicator');
            setStatus(`<i class="fas fa-rocket" style="margin-right:8px;color:#00ff88"></i> Misez sur <strong style="color:#00ff88">${currentPrediction.value.toFixed(2)}X</strong> !`);
            document.getElementById('roundsIndicator').style.display = 'flex';
            updateRoundDots(0);
            setTimeout(() => startRoundValidation(), 5000);
        }

        async function startRoundValidation() {
            showIndicator('validationIndicator');
            setStatus(`<i class="fas fa-satellite-dish" style="margin-right:8px;color:#ff8800"></i> Surveillance active...`);
            validationRounds = 0;
            try {
                const res = await apGet('/rocketqueen/coefficients?limit=1');
                lastKnownCoefId = res.data[0].id ?? (res.data[0].coef + '_' + res.data[0].timestamp);
                lastKnownCoefValue = res.data[0].coef;
            } catch (e) { }

            validationInterval = setInterval(async () => {
                try {
                    const res = await apGet('/rocketqueen/coefficients?limit=3');
                    const coefs = res.data; let newTour = false;
                    for (const c of coefs) {
                        const cId = c.id ?? (c.coef + '_' + c.timestamp);
                        if (cId === lastKnownCoefId) break;
                        newTour = true; validationRounds++;
                        updateRoundDots(validationRounds);
                        setStatus(`<i class="fas fa-chart-line" style="margin-right:8px;color:#ff8800"></i> Tour ${validationRounds} : <strong>${c.coef.toFixed(2)}X</strong> / cible ≥ ${currentPrediction.value.toFixed(2)}X`);
                        if (c.coef >= currentPrediction.value) {
                            lastKnownCoefId = cId; clearInterval(validationInterval);
                            updateRoundDots(validationRounds, true); finishValidation(true, c.coef); return;
                        }
                        if (validationRounds >= MAX_ROUNDS) {
                            lastKnownCoefId = cId; clearInterval(validationInterval);
                            updateRoundDots(validationRounds, false); finishValidation(false, c.coef); return;
                        }
                    }
                    if (newTour) {
                        lastKnownCoefId = coefs[0].id ?? (coefs[0].coef + '_' + coefs[0].timestamp);
                        lastKnownCoefValue = coefs[0].coef;
                    }
                } catch (e) { console.error(e); }
            }, 3000);
        }

        function finishValidation(success, mult) {
            hideAllIndicators(); setResultMode(success); setWaveColor(success ? 'green' : 'red');
            setStatus(success
                ? `<i class="fas fa-check-circle" style="margin-right:8px;color:#00ff88"></i> Validé tour ${validationRounds} — <strong style="color:#00ff88">${mult?.toFixed(2)}X</strong>`
                : `<i class="fas fa-times-circle" style="margin-right:8px;color:#ff4444"></i> Échec après ${MAX_ROUNDS} tours`);
            document.getElementById('multiplierText').classList.add('pulse');
            setTimeout(() => resetPrediction(), 5000);
        }

        function resetPrediction() {
            document.getElementById('multiplierText').classList.remove('pulse');
            hideAllIndicators();
            document.getElementById('roundsIndicator').style.display = 'none';
            document.getElementById('confidenceBadge').style.display = 'none';
            document.getElementById('countdown').textContent = '';
            document.getElementById('countdown').className = '';
            isPredictionActive = false; currentPrediction = null;
            validationRounds = 0; lastKnownCoefId = null; lastKnownCoefValue = null;
            if (validationInterval) { clearInterval(validationInterval); validationInterval = null; }
            if (predictionTimeout) { clearTimeout(predictionTimeout); predictionTimeout = null; }
            setWaveColor('orange'); setWaitMode(); updateRoundDots(0); updateCurrentTime();
            setStatus(`<i class="fas fa-circle-notch fa-spin" style="margin-right:8px;color:#ff6600"></i> Analyse en cours...`);
        }
    
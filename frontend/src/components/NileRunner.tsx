import { useEffect, useRef, useState } from "react";
import crocodileSprite from "../assets/game/crocodile.png";
import nefertitiSprite from "../assets/game/nefertiti-game.png";
import obstacleSprite from "../assets/game/obstacle-game.png";
import pyramidSprite from "../assets/game/pyramid.png";

type NileRunnerProps = {
  open: boolean;
  onClose: () => void;
};

type GameMode = "idle" | "running" | "over";

type Obstacle = {
  x: number;
  w: number;
  h: number;
};

type SpriteKey = "player" | "croc" | "obstacle" | "pyramid";

type SpriteMetrics = {
  aspect: number;
  minX: number;
  maxX: number;
  minY: number;
  maxY: number;
};

const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, value));

export default function NileRunner({ open, onClose }: NileRunnerProps) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const rafRef = useRef<number | null>(null);
  const spritesRef = useRef<{
    player: HTMLImageElement | null;
    croc: HTMLImageElement | null;
    obstacle: HTMLImageElement | null;
    pyramid: HTMLImageElement | null;
  }>({
    player: null,
    croc: null,
    obstacle: null,
    pyramid: null
  });
  const spriteMetricsRef = useRef<Record<SpriteKey, SpriteMetrics>>({
    player: { aspect: 1.5, minX: 0, maxX: 1, minY: 0, maxY: 1 },
    croc: { aspect: 1, minX: 0, maxX: 1, minY: 0, maxY: 1 },
    obstacle: { aspect: 1.5, minX: 0, maxX: 1, minY: 0, maxY: 1 },
    pyramid: { aspect: 1, minX: 0, maxX: 1, minY: 0, maxY: 1 }
  });
  const stateRef = useRef({
    width: 900,
    height: 360,
    groundY: 300,
    playerX: 120,
    playerWidth: 64,
    playerHeight: 84,
    playerY: 0,
    playerVY: 0,
    jumpCount: 0,
    maxJumps: 2,
    gravity: 2400,
    jumpVelocity: -900,
    doubleJumpVelocity: -780,
    speed: 300,
    speedBoost: 12,
    crocMode: "idle",
    crocWave: 0,
    crocDistance: 440,
    crocSpeed: 0,
    crocChaseWindow: 0,
    crocSpawnTimer: 2.8,
    crocWidth: 74,
    crocHeight: 38,
    crocRetreatBoost: 260,
    obstacleMinH: 52,
    obstacleMaxH: 80,
    obstacleMinW: 48,
    obstacleMaxW: 82,
    spawnTimer: 0,
    obstacles: [] as Obstacle[],
    score: 0,
    hudTimer: 0,
    lastTime: 0
  });

  const [mode, setMode] = useState<GameMode>("idle");
  const modeRef = useRef<GameMode>("idle");
  const [displayScore, setDisplayScore] = useState(0);

  const resetGame = () => {
    const state = stateRef.current;
    state.playerY = state.groundY;
    state.playerVY = 0;
    state.jumpCount = 0;
    state.speed = 300;
    state.crocMode = "idle";
    state.crocWave = 0;
    state.crocDistance = 440;
    state.crocSpeed = 0;
    state.crocChaseWindow = 0;
    state.crocSpawnTimer = 2.8;
    state.spawnTimer = 0.9;
    state.obstacles = [];
    state.score = 0;
    state.hudTimer = 0;
    state.lastTime = 0;
    setDisplayScore(0);
  };

  const setModeSafe = (next: GameMode) => {
    modeRef.current = next;
    setMode(next);
  };

  const buildSpriteMetrics = (image: HTMLImageElement | null, fallbackAspect: number): SpriteMetrics => {
    if (!image) {
      return { aspect: fallbackAspect, minX: 0, maxX: 1, minY: 0, maxY: 1 };
    }

    const width = image.naturalWidth || image.width;
    const height = image.naturalHeight || image.height;
    if (!width || !height) {
      return { aspect: fallbackAspect, minX: 0, maxX: 1, minY: 0, maxY: 1 };
    }

    const scanCanvas = document.createElement("canvas");
    scanCanvas.width = width;
    scanCanvas.height = height;
    const scanCtx = scanCanvas.getContext("2d", { willReadFrequently: true });
    if (!scanCtx) {
      return { aspect: width / height, minX: 0, maxX: 1, minY: 0, maxY: 1 };
    }

    scanCtx.drawImage(image, 0, 0, width, height);
    const imageData = scanCtx.getImageData(0, 0, width, height).data;
    let minX = width;
    let minY = height;
    let maxX = -1;
    let maxY = -1;
    const alphaThreshold = 18;
    for (let y = 0; y < height; y += 1) {
      for (let x = 0; x < width; x += 1) {
        const alpha = imageData[(y * width + x) * 4 + 3];
        if (alpha < alphaThreshold) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }

    if (maxX < minX || maxY < minY) {
      return { aspect: width / height, minX: 0, maxX: 1, minY: 0, maxY: 1 };
    }

    return {
      aspect: width / height,
      minX: minX / width,
      maxX: (maxX + 1) / width,
      minY: minY / height,
      maxY: (maxY + 1) / height
    };
  };

  const getAnchoredTop = (key: SpriteKey, baselineY: number, spriteHeight: number) => {
    const metrics = spriteMetricsRef.current[key];
    return baselineY - spriteHeight + (1 - metrics.maxY) * spriteHeight;
  };

  const getSpriteContentBox = (
    key: SpriteKey,
    x: number,
    y: number,
    width: number,
    height: number
  ) => {
    const metrics = spriteMetricsRef.current[key];
    return {
      x: x + metrics.minX * width,
      y: y + metrics.minY * height,
      w: Math.max(1, (metrics.maxX - metrics.minX) * width),
      h: Math.max(1, (metrics.maxY - metrics.minY) * height)
    };
  };

  const syncSpriteSizing = () => {
    const state = stateRef.current;
    const metrics = spriteMetricsRef.current;
    const playerAspect = metrics.player.aspect || 1;
    const crocAspect = metrics.croc.aspect || 1;
    const obstacleAspect = metrics.obstacle.aspect || 1;

    state.playerHeight = Math.round(clamp(state.height * 0.3, 82, 122));
    state.playerWidth = Math.round(state.playerHeight * playerAspect);
    state.crocHeight = Math.round(clamp(state.height * 0.22, 58, 90));
    state.crocWidth = Math.round(state.crocHeight * crocAspect);
    state.obstacleMinH = Math.round(clamp(state.height * 0.19, 52, 80));
    state.obstacleMaxH = Math.round(clamp(state.height * 0.26, 70, 104));
    state.obstacleMinW = Math.round(state.obstacleMinH * obstacleAspect);
    state.obstacleMaxW = Math.round(state.obstacleMaxH * obstacleAspect);
  };

  const resizeCanvas = () => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const parent = canvas.parentElement;
    if (!parent) return;
    const rect = parent.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const width = Math.max(320, rect.width);
    const height = Math.max(220, Math.min(420, rect.width * 0.4));
    canvas.width = width * dpr;
    canvas.height = height * dpr;
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    const state = stateRef.current;
    state.width = width;
    state.height = height;
    state.groundY = height - 60;
    syncSpriteSizing();
    state.playerY = Math.min(state.playerY || state.groundY, state.groundY);
  };

  const jump = () => {
    const state = stateRef.current;
    const onGround = state.playerY >= state.groundY - 1;
    if (onGround) {
      state.jumpCount = 0;
    }
    if (state.jumpCount >= state.maxJumps) return;
    const isDoubleJump = state.jumpCount === 1;
    state.playerVY = isDoubleJump ? state.doubleJumpVelocity : state.jumpVelocity;
    state.jumpCount += 1;

    // Successful double jump can push an active crocodile chase further back.
    if (isDoubleJump && state.crocMode === "chase" && state.crocDistance < 200) {
      state.crocDistance += state.crocRetreatBoost;
    }
  };

  const startGame = () => {
    resetGame();
    setModeSafe("running");
  };

  const endGame = () => {
    setDisplayScore(stateRef.current.score);
    setModeSafe("over");
  };

  const update = (timestamp: number) => {
    const state = stateRef.current;
    if (!state.lastTime) {
      state.lastTime = timestamp;
    }
    const rawDt = Math.min(0.2, (timestamp - state.lastTime) / 1000);
    const dt = Math.min(0.05, rawDt);
    state.lastTime = timestamp;

    if (modeRef.current === "running") {
      state.speed = Math.min(610, state.speed + state.speedBoost * dt);

      state.playerVY += state.gravity * dt;
      state.playerY += state.playerVY * dt;
      if (state.playerY > state.groundY) {
        state.playerY = state.groundY;
        state.playerVY = 0;
        state.jumpCount = 0;
      }

      state.spawnTimer -= dt;
      if (state.spawnTimer <= 0) {
        const h = state.obstacleMinH + Math.random() * (state.obstacleMaxH - state.obstacleMinH);
        const w = state.obstacleMinW + Math.random() * (state.obstacleMaxW - state.obstacleMinW);
        state.obstacles.push({
          x: state.width + 40,
          w,
          h
        });
        state.spawnTimer = 0.8 + Math.random() * 0.65;
      }

      state.obstacles.forEach((obs) => {
        obs.x -= state.speed * dt;
      });
      state.obstacles = state.obstacles.filter((obs) => obs.x + obs.w > -20);

      const playerTop = getAnchoredTop("player", state.playerY, state.playerHeight);
      const playerContentBox = getSpriteContentBox("player", state.playerX, playerTop, state.playerWidth, state.playerHeight);
      const playerBox = {
        x: playerContentBox.x + playerContentBox.w * 0.12,
        y: playerContentBox.y + playerContentBox.h * 0.06,
        w: playerContentBox.w * 0.72,
        h: playerContentBox.h * 0.9
      };
      for (const obs of state.obstacles) {
        const obstacleTop = getAnchoredTop("obstacle", state.groundY, obs.h);
        const obstacleContentBox = getSpriteContentBox("obstacle", obs.x, obstacleTop, obs.w, obs.h);
        const obstacleBox = {
          x: obstacleContentBox.x + obstacleContentBox.w * 0.12,
          y: obstacleContentBox.y + obstacleContentBox.h * 0.08,
          w: obstacleContentBox.w * 0.76,
          h: obstacleContentBox.h * 0.9
        };
        const hit =
          playerBox.x < obstacleBox.x + obstacleBox.w &&
          playerBox.x + playerBox.w > obstacleBox.x &&
          playerBox.y < obstacleBox.y + obstacleBox.h &&
          playerBox.y + playerBox.h > obstacleBox.y;
        if (hit) {
          endGame();
          break;
        }
      }

      if (state.crocMode === "chase") {
        const maxChaseSpeed = Math.max(520, state.speed * 1.45);
        state.crocSpeed = Math.min(maxChaseSpeed, state.crocSpeed + 340 * dt);
        state.crocDistance -= state.crocSpeed * dt;
        state.crocChaseWindow -= dt;

        const playerAirborne = state.playerY < state.groundY - state.playerHeight * 0.35;
        if (state.crocDistance <= 20 && playerAirborne) {
          state.crocMode = "retreat";
          state.crocSpeed = Math.max(state.crocSpeed, state.speed * 1.2);
        } else if (state.crocDistance <= 0) {
          endGame();
        } else if (state.crocChaseWindow <= 0) {
          state.crocMode = "retreat";
          state.crocSpeed = Math.max(state.crocSpeed, state.speed);
        }
      } else if (state.crocMode === "retreat") {
        state.crocSpeed = Math.min(760, state.crocSpeed + 260 * dt);
        state.crocDistance += state.crocSpeed * dt;
        if (state.crocDistance > state.width + state.crocWidth + 180) {
          state.crocMode = "idle";
          state.crocSpawnTimer = 2.8 + Math.random() * 2.6;
          state.crocDistance = state.width + 200;
          state.crocSpeed = 0;
        }
      } else {
        state.crocSpawnTimer -= dt;
        if (state.crocSpawnTimer <= 0) {
          state.crocMode = "chase";
          state.crocWave += 1;
          state.crocDistance = 360 + Math.random() * 170;
          const waveBoost = Math.min(180, state.crocWave * 22);
          state.crocSpeed = Math.max(380, state.speed * 1.08 + waveBoost);
          state.crocChaseWindow = 2.5 + Math.random() * 1.8;
        }
      }

      state.score += rawDt;
      state.hudTimer += rawDt;
      if (state.hudTimer >= 0.05) {
        setDisplayScore(state.score);
        state.hudTimer = 0;
      }
    }

    draw();
    rafRef.current = requestAnimationFrame(update);
  };

  const draw = () => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const state = stateRef.current;
    const dpr = window.devicePixelRatio || 1;
    ctx.save();
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, state.width, state.height);

    const gradient = ctx.createLinearGradient(0, 0, 0, state.height);
    gradient.addColorStop(0, "#2a1b0f");
    gradient.addColorStop(0.6, "#8b5a2b");
    gradient.addColorStop(1, "#2b1b0e");
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, state.width, state.height);

    ctx.fillStyle = "#f7d774";
    ctx.beginPath();
    ctx.arc(state.width - 120, 80, 36, 0, Math.PI * 2);
    ctx.fill();

    ctx.fillStyle = "#5a3c20";
    ctx.fillRect(0, state.groundY, state.width, state.height - state.groundY);

    const sprites = spritesRef.current;
    const drawSprite = (
      key: SpriteKey,
      x: number,
      y: number,
      width: number,
      height: number,
      alpha = 1
    ) => {
      const image = sprites[key];
      if (!image) return false;
      ctx.save();
      if (alpha < 1) {
        ctx.globalAlpha = alpha;
      }
      ctx.drawImage(image, x, y, width, height);
      ctx.restore();
      return true;
    };

    drawSprite("pyramid", state.width - 300, state.groundY - 190, 250, 170, 0.18);

    state.obstacles.forEach((obs) => {
      const obstacleTop = getAnchoredTop("obstacle", state.groundY, obs.h);
      if (!drawSprite("obstacle", obs.x, obstacleTop, obs.w, obs.h)) {
        ctx.fillStyle = "#d9b16f";
        ctx.fillRect(obs.x, obstacleTop, obs.w, obs.h);
      }
    });

    const crocX = state.playerX - state.crocDistance;
    const crocTop = getAnchoredTop("croc", state.groundY, state.crocHeight);
    const crocVisible = state.crocMode === "chase" || state.crocMode === "retreat";
    if (crocVisible) {
      if (!drawSprite("croc", crocX, crocTop, state.crocWidth, state.crocHeight)) {
        ctx.fillStyle = "#2c5d3a";
        ctx.fillRect(crocX, crocTop, state.crocWidth, state.crocHeight);
        ctx.fillStyle = "#1d3b25";
        ctx.fillRect(crocX + state.crocWidth - 18, crocTop + 8, 16, 10);
      }
    }

    const playerTop = getAnchoredTop("player", state.playerY, state.playerHeight);
    if (!drawSprite("player", state.playerX, playerTop, state.playerWidth, state.playerHeight)) {
      ctx.fillStyle = "#f2d3b3";
      ctx.fillRect(state.playerX, playerTop, state.playerWidth, state.playerHeight);
      ctx.fillStyle = "#c49b6f";
      ctx.fillRect(state.playerX + 10, playerTop - 16, 44, 16);
    }

    ctx.fillStyle = "#f8e9cd";
    ctx.font = "16px 'Space Mono', monospace";
    ctx.fillText(`Survival: ${displayScore.toFixed(1)}s`, 20, 30);
    if (state.crocMode === "chase") {
      ctx.fillText(`Crocodile chase #${state.crocWave}`, 20, 50);
    } else if (state.crocMode === "retreat") {
      ctx.fillText("Crocodile retreating...", 20, 50);
    } else {
      ctx.fillText(`Next crocodile: ${Math.max(0, state.crocSpawnTimer).toFixed(1)}s`, 20, 50);
    }

    if (modeRef.current === "idle") {
      ctx.fillStyle = "rgba(0,0,0,0.4)";
      ctx.fillRect(0, 0, state.width, state.height);
      ctx.fillStyle = "#f8e9cd";
      ctx.font = "20px 'Cinzel Decorative', serif";
      ctx.fillText("Nile Runner", 20, 80);
      ctx.font = "14px 'Space Mono', monospace";
      ctx.fillText("Press Space / Tap to jump. Double jump to evade crocodiles.", 20, 110);
      ctx.fillText("Click Start to begin.", 20, 135);
    }

    if (modeRef.current === "over") {
      ctx.fillStyle = "rgba(0,0,0,0.5)";
      ctx.fillRect(0, 0, state.width, state.height);
      ctx.fillStyle = "#f8e9cd";
      ctx.font = "20px 'Cinzel Decorative', serif";
      ctx.fillText("Caught by the crocodile!", 20, 80);
      ctx.font = "14px 'Space Mono', monospace";
      ctx.fillText(`Survived ${displayScore.toFixed(1)}s`, 20, 110);
      ctx.fillText("Press Enter or click Restart.", 20, 135);
    }

    ctx.restore();
  };

  useEffect(() => {
    if (typeof window === "undefined") return;
    let mounted = true;
    const loadImage = (src: string) =>
      new Promise<HTMLImageElement | null>((resolve) => {
        const image = new Image();
        image.onload = () => resolve(image);
        image.onerror = () => resolve(null);
        image.src = src;
      });

    Promise.all([
      loadImage(nefertitiSprite),
      loadImage(crocodileSprite),
      loadImage(obstacleSprite),
      loadImage(pyramidSprite)
    ]).then(([player, croc, obstacle, pyramid]) => {
      if (!mounted) return;
      spritesRef.current = { player, croc, obstacle, pyramid };
      spriteMetricsRef.current = {
        player: buildSpriteMetrics(player, 1.5),
        croc: buildSpriteMetrics(croc, 1),
        obstacle: buildSpriteMetrics(obstacle, 1.5),
        pyramid: buildSpriteMetrics(pyramid, 1)
      };
      syncSpriteSizing();
    });

    return () => {
      mounted = false;
    };
  }, []);

  useEffect(() => {
    if (!open) return;
    resizeCanvas();
    resetGame();
    setModeSafe("idle");

    const handleKey = (event: KeyboardEvent) => {
      if (!open) return;
      if (event.key === " " || event.key === "ArrowUp") {
        event.preventDefault();
        if (modeRef.current === "idle") {
          startGame();
          return;
        }
        jump();
      }
      if (event.key === "Enter") {
        if (modeRef.current !== "running") {
          startGame();
        }
      }
      if (event.key === "Escape") {
        onClose();
      }
    };

    const handlePointer = () => {
      if (!open) return;
      if (modeRef.current === "idle") {
        startGame();
        return;
      }
      jump();
    };

    window.addEventListener("keydown", handleKey);
    window.addEventListener("resize", resizeCanvas);
    const canvas = canvasRef.current;
    canvas?.addEventListener("pointerdown", handlePointer);

    rafRef.current = requestAnimationFrame(update);

    return () => {
      window.removeEventListener("keydown", handleKey);
      window.removeEventListener("resize", resizeCanvas);
      canvas?.removeEventListener("pointerdown", handlePointer);
      if (rafRef.current) cancelAnimationFrame(rafRef.current);
    };
  }, [open]);

  if (!open) return null;

  return (
    <div className="nile-runner__overlay">
      <div className="nile-runner__panel">
        <div className="nile-runner__header">
          <div>
            <div className="nile-runner__title">Nile Runner</div>
            <div className="nile-runner__subtitle">
              Guide Nefertiti across the desert. Crocodiles attack in fast waves.
            </div>
          </div>
          <button className="btn btn--ghost" type="button" onClick={onClose}>
            Close
          </button>
        </div>
        <div className="nile-runner__canvas">
          <canvas ref={canvasRef} />
        </div>
        <div className="nile-runner__controls">
          <button
            className="btn btn--primary"
            type="button"
            onClick={() => startGame()}
            disabled={mode === "running"}
          >
            {mode === "over" ? "Restart" : "Start"}
          </button>
          <div className="nile-runner__hint">
            Jump: Space / Tap · Double jump to evade · Escape closes
          </div>
        </div>
      </div>
    </div>
  );
}

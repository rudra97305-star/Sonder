from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import subprocess
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from tempfile import TemporaryDirectory, TemporaryFile
from time import perf_counter
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from kim_engine import KimEngine, open_engine

ROOT = Path(__file__).parent.resolve()
DATA = ROOT / "data"
DATA.mkdir(exist_ok=True)
IMPORTS = DATA / "audio-imports"
OUTPUT_SETTINGS = DATA / "output-folder.json"
MAX_AUDIO_BYTES = 128 * 1024 * 1024
jobs: list[dict[str, Any]] = []


@asynccontextmanager
async def lifespan(_app: FastAPI):
    if model_ready() or LOCAL_MODEL.is_file():
        warm_gpu()
    yield


app = FastAPI(title="Sonder", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=ROOT / "static"), name="static")
logger = logging.getLogger("uvicorn.error")
UVR_SOURCE = ROOT / "vendor" / "uvr-headless-master"
LOCAL_MODEL = Path(r"D:\Ultimate Vocal Remover\models\MDX_Net_Models\Kim_Vocal_2.onnx")
GPU_RUNTIME = ROOT / "vendor" / "kim-runtime"
SHARE_RUNTIME = (ROOT / "desktop" / "shared-runtime.txt").is_file()
INSTALLED_RUNTIME = (ROOT / "desktop" / "installed-runtime.txt").is_file()
REPAIR_SETUP = ("Run Sonder-Setup.exe again to repair the installation." if INSTALLED_RUNTIME
                else "Extract the entire Sonder ZIP and run Setup Sonder.cmd.")
engine_task: asyncio.Task[KimEngine | None] | None = None
engine_state: dict[str, str | None] = {"engine_status": "idle", "provider": None, "engine_error": None}
DEFAULT_OUTPUT_DIR = str(Path.home() / "Music" / "Sonder")
AUDIO_SUFFIXES = {".aac", ".aif", ".aiff", ".flac", ".m4a", ".mp3", ".oga", ".ogg", ".opus", ".wav", ".wma"}
active_jobs: dict[Path, tuple[dict[str, Any], asyncio.Task[None]]] = {}


class PollLogFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        return not (isinstance(args, tuple) and len(args) == 5 and args[1:3] == ("GET", "/api/status") and args[4] == 200)


logging.getLogger("uvicorn.access").addFilter(PollLogFilter())


def uvr_source_root() -> Path:
    if SHARE_RUNTIME:
        return UVR_SOURCE
    return Path(os.environ.get("UVR_BASE_PATH") or UVR_SOURCE)


def model_path() -> Path:
    return uvr_source_root() / "models" / "MDX_Net_Models" / LOCAL_MODEL.name


def model_ready() -> bool:
    try:
        return model_path().stat().st_size == 66_759_214
    except OSError:
        return False


def import_local_model() -> bool:
    if model_ready():
        return True
    if SHARE_RUNTIME or not LOCAL_MODEL.is_file() or not LOCAL_MODEL.stat().st_size:
        return False
    destination = model_path()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(f".{uuid.uuid4().hex}.tmp")
    try:
        shutil.copyfile(LOCAL_MODEL, temporary)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return True


@app.exception_handler(Exception)
async def unexpected_error(request: Request, exc: Exception):
    return JSONResponse(
        status_code=500,
        content={"detail": f"{type(exc).__name__} while handling {request.url.path}. See the server window for details."},
    )


def warm_gpu() -> asyncio.Task[KimEngine | None]:
    global engine_task
    if engine_task is None or (engine_task.done() and engine_state["engine_status"] not in ("gpu_ready", "cpu_ready")):
        engine_state.update(engine_status="warming", provider=None, engine_error=None)
        engine_task = asyncio.create_task(prepare_gpu())
    return engine_task


async def prepare_gpu() -> KimEngine | None:
    started = perf_counter()
    try:
        if not await asyncio.to_thread(import_local_model):
            message = (REPAIR_SETUP if SHARE_RUNTIME
                       else "Install Kim Vocal 2 in Settings first.")
            engine_state.update(engine_status="idle", engine_error=message)
            return None
        engine = await asyncio.to_thread(open_engine, model_path(), GPU_RUNTIME, SHARE_RUNTIME)
    except Exception as exc:
        logger.error("Kim Vocal 2 initialization failed: %s", exc)
        message = (f"Kim Vocal 2 could not start. {REPAIR_SETUP}" if SHARE_RUNTIME else
                   "Kim Vocal 2 could not start on the GPU. Check your graphics driver and rerun Sonder setup.")
        engine_state.update(engine_status="error", engine_error=message)
        return None
    engine_state.update(engine_status="cpu_ready" if engine.provider == "CPU" else "gpu_ready", provider=engine.provider)
    logger.info("Kim Vocal 2 ready on %s in %.1f seconds", engine.device_label, perf_counter() - started)
    return engine


def find_ffmpeg() -> str | None:
    if not SHARE_RUNTIME:
        installed = shutil.which("ffmpeg")
        if installed:
            return installed
        fallback = LOCAL_MODEL.parents[2] / "ffmpeg.exe"
        if fallback.is_file():
            return str(fallback)
    try:
        from imageio_ffmpeg import get_ffmpeg_exe
        return get_ffmpeg_exe()
    except (ImportError, RuntimeError):
        return None


def encode_mp3(ffmpeg: str, source: Path, destination: Path) -> None:
    result = subprocess.run(
        [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
         "-map", "0:a:0", "-c:a", "libmp3lame", "-b:a", "320k", "-ar", "44100", "-ac", "2",
         str(destination)],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=180,
    )
    if result.returncode or not destination.is_file() or not destination.stat().st_size:
        error = result.stderr.strip()[-1200:] or "FFmpeg did not produce an MP3."
        raise RuntimeError(f"Could not export {destination.name}. {error}")


async def download_uvr_model() -> str:
    import sys

    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    if (UVR_SOURCE / "gui_data" / "constants.py").is_file():
        env.setdefault("UVR_BASE_PATH", str(UVR_SOURCE))
        env["PYTHONPATH"] = os.pathsep.join(filter(None, (str(UVR_SOURCE), env.get("PYTHONPATH"))))
    result = await asyncio.to_thread(
        subprocess.run,
        [sys.executable, "-X", "utf8", "-m", "uvr_headless.cli", "download", "Kim Vocal 2"],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        errors="replace",
        timeout=180,
    )
    if result.returncode:
        logger.error("UVR model download failed:\n%s", result.stdout)
        raise RuntimeError(result.stdout.strip()[-1800:] or f"UVR exited with code {result.returncode}.")
    return result.stdout.strip()


def safe_name(value: str) -> str:
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", value).strip(" .")
    name = value[:120].rstrip(" .") or "Untitled"
    if re.fullmatch(r"(?i:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])", name.split(".")[0].rstrip()):
        return "_" + name
    return name


@app.get("/")
async def home():
    return FileResponse(ROOT / "static" / "index.html")


@app.get("/api/status")
async def status():
    return JSONResponse({"jobs": jobs}, headers={"Cache-Control": "no-store"})


def output_folder() -> Path:
    try:
        selected = Path(json.loads(OUTPUT_SETTINGS.read_text(encoding="utf-8"))["folder"])
        if selected.is_absolute():
            return selected
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return Path(DEFAULT_OUTPUT_DIR)


class OutputFolder(BaseModel):
    folder: str


@app.get("/api/output-folder")
async def get_output_folder():
    return JSONResponse({"folder": str(output_folder())}, headers={"Cache-Control": "no-store"})


@app.post("/api/output-folder")
async def set_output_folder(request: Request, data: OutputFolder):
    if request.headers.get("origin") not in (None, str(request.base_url).rstrip("/")):
        raise HTTPException(403, "Open Sonder to change the output folder.")
    try:
        folder = Path(data.folder.strip()).expanduser()
        if not folder.is_absolute() or not folder.is_dir():
            raise HTTPException(400, "Choose an existing folder.")
        folder = folder.resolve()
        with TemporaryFile(dir=folder):
            pass
    except (OSError, ValueError, RuntimeError) as exc:
        raise HTTPException(400, "Sonder cannot write to that folder. Choose another location.") from exc

    temporary = OUTPUT_SETTINGS.with_suffix(f".{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_text(json.dumps({"folder": str(folder)}, ensure_ascii=False), encoding="utf-8")
        temporary.replace(OUTPUT_SETTINGS)
    except OSError as exc:
        raise HTTPException(500, "Sonder could not remember this folder.") from exc
    finally:
        temporary.unlink(missing_ok=True)
    return {"folder": str(folder)}


@app.post("/api/audio/import", status_code=202)
async def import_audio(request: Request, name: str):
    if request.headers.get("origin") not in (None, str(request.base_url).rstrip("/")):
        raise HTTPException(403, "Open Sonder to import audio.")
    if request.headers.get("content-type") != "application/octet-stream":
        raise HTTPException(415, "Send an audio file from Sonder.")
    name = name.replace(chr(92), "/").rsplit("/", 1)[-1]
    suffix = Path(name).suffix.lower()
    if suffix not in AUDIO_SUFFIXES:
        raise HTTPException(415, "Choose an MP3, WAV, FLAC, or another supported audio file.")
    title = Path(name).stem[:160]
    folder = (output_folder() / safe_name(title)).resolve()
    IMPORTS.mkdir(exist_ok=True)
    source = IMPORTS / f"{uuid.uuid4().hex}{suffix}"
    size = 0
    try:
        with source.open("xb") as audio:
            async for chunk in request.stream():
                size += len(chunk)
                if size > MAX_AUDIO_BYTES:
                    raise HTTPException(413, "Choose an audio file smaller than 128 MB.")
                audio.write(chunk)
        if not size:
            raise HTTPException(400, "This audio file is empty.")
        existing = active_jobs.get(folder)
        if existing and not existing[1].done():
            raise HTTPException(409, "A track with this name is already being processed.")
        job = start_processing(title, source, folder)
    except BaseException:
        source.unlink(missing_ok=True)
        raise
    return {"job": job}


def start_processing(title: str, source: Path, folder: Path):
    job = {
        "id": uuid.uuid4().hex[:8], "title": title, "status": "Audio received",
        "progress": 30, "folder": str(folder),
    }
    jobs.insert(0, job)
    task = asyncio.create_task(process_track(source, folder, job))
    active_jobs[folder] = job, task

    def forget(finished: asyncio.Task[None]) -> None:
        if active_jobs.get(folder, (None, None))[1] is finished:
            del active_jobs[folder]

    task.add_done_callback(forget)
    return job


async def process_track(source: Path, folder: Path, job: dict[str, Any]) -> None:
    def separation_progress(percent: int) -> None:
        percent = min(100, percent)
        progress = 30 + percent * 55 // 100
        if progress >= job["progress"]:
            job.update(status=f"Separating on {engine.device_label} ({percent}%)", progress=progress)

    title = job["title"]
    try:
        ffmpeg = find_ffmpeg()
        if not ffmpeg:
            raise RuntimeError("FFmpeg is required to export 320 kbps MP3. Add FFmpeg to PATH and restart Sonder.")
        gpu = warm_gpu()
        folder.mkdir(parents=True, exist_ok=True)
        with TemporaryDirectory(prefix=".sonder-", dir=folder) as temporary:
            staging = Path(temporary)
            if not gpu.done():
                job.update(status="Warming up Kim Vocal 2", progress=30)
            engine = await asyncio.shield(gpu)
            if engine is None:
                raise RuntimeError(engine_state["engine_error"] or "Kim Vocal 2 is unavailable.")

            loop = asyncio.get_running_loop()
            vocals, instrumental = staging / "vocals.wav", staging / "instrumental.wav"
            job.update(status=f"Preparing audio for {engine.device_label}", progress=30)
            logger.info("Starting Kim Vocal 2 for %s on %s.", title, engine.device_label)
            started = perf_counter()
            await asyncio.to_thread(
                engine.separate, ffmpeg, source, vocals, instrumental,
                lambda percent: loop.call_soon_threadsafe(separation_progress, percent),
            )
            logger.info("Kim Vocal 2 separated %s in %.1f seconds on %s.", title, perf_counter() - started, engine.device_label)
            files = {"original.mp3": source, "vocals.mp3": vocals, "instrumental.mp3": instrumental}
            if not all(path.is_file() and path.stat().st_size for path in files.values()):
                raise RuntimeError("Kim Vocal 2 did not produce both stems.")
            job.update(status="Exporting 320 kbps MP3s", progress=86)
            for index, (name, path) in enumerate(files.items(), start=1):
                await asyncio.to_thread(encode_mp3, ffmpeg, path, staging / name)
                job["progress"] = 86 + 4 * index
            for name in files:
                (staging / name).replace(folder / name)
        job.update(status="Complete", progress=100)
        logger.info("Saved three 320 kbps MP3s for %s in %s", title, folder)
    except asyncio.CancelledError:
        job.update(status="Could not finish", progress=0, error="Sonder stopped before finishing.", error_status=503)
        raise
    except Exception as e:
        error = str(e)[-1500:] or type(e).__name__
        job.update(status="Could not finish", progress=0, error=error, error_status=504 if isinstance(e, TimeoutError) else 500)
        logger.warning("Processing failed for %s: %s", title, error)
    finally:
        source.unlink(missing_ok=True)


@app.get("/api/model")
async def model_status():
    return JSONResponse({"ready": model_ready(), **engine_state}, headers={"Cache-Control": "no-store"})


@app.post("/api/model")
async def model():
    if model_ready():
        warm_gpu()
        return {"ok": True, "message": "Kim Vocal 2 is installed and ready."}
    if SHARE_RUNTIME:
        raise HTTPException(503, f"The bundled Kim Vocal 2 model is missing or damaged. {REPAIR_SETUP}")
    try:
        if await asyncio.to_thread(import_local_model):
            warm_gpu()
            return {"ok": True, "message": "Kim Vocal 2 is ready. Sonder used your local model file."}
        output = await download_uvr_model()
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(504, "The model download timed out. Check your connection and try again.") from exc
    except (OSError, RuntimeError) as exc:
        raise HTTPException(500, f"Kim Vocal 2 download failed. {exc}") from exc
    warm_gpu()
    return {"ok": True, "message": output[-1500:]}

const $ = s => document.querySelector(s);
const modal = $('#settingsModal'), toast = $('#toast');
let toastTimer;
function notify(message){toast.textContent=message;toast.hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>toast.hidden=true,3800)}
async function api(url, body, signal) {
  const response = await fetch(url, {
    method: body ? 'POST' : 'GET',
    headers: body ? {'Content-Type': 'application/json'} : {},
    body: body ? JSON.stringify(body) : undefined,
    signal,
  });
  const data = await response.json().catch(() => null);
  if (!response.ok || !data) {
    const detail = typeof data?.detail === 'string' ? data.detail : null;
    throw new Error(detail || `Request failed (HTTP ${response.status}). See the server window for details.`);
  }
  return data;
}
function isActiveJob(job) {
  return !job.error && job.status !== 'Complete' && job.status !== 'Could not finish';
}

function renderJobs(jobs) {
  const box = $('#jobs');
  if (!jobs.length) {
    box.className = 'jobs-empty';
    box.innerHTML = '<span class="empty-icon">◌</span><p>Your processed tracks will appear here.</p>';
    return;
  }
  box.className = '';
  const rows = document.createDocumentFragment();
  for (const job of jobs) {
    const row = document.createElement('div');
    row.className = 'job-row';
    row.innerHTML = '<div><b></b><small></small></div><div class="job-state"><span></span></div>';
    row.querySelector('b').textContent = job.title;
    row.querySelector('small').textContent = [job.folder, job.error].filter(Boolean).join(' · ');
    const state = row.querySelector('.job-state');
    state.querySelector('span').textContent = job.status.toUpperCase();
    if (isActiveJob(job) && Number.isFinite(job.progress)) {
      const indicator = document.createElement('div');
      indicator.className = 'job-progress';
      const trackProgress = document.createElement('progress');
      trackProgress.max = 100;
      trackProgress.value = Math.round(job.progress);
      trackProgress.setAttribute('aria-label', `Overall progress for ${job.title}`);
      const percent = document.createElement('span');
      percent.textContent = `${trackProgress.value}%`;
      percent.setAttribute('aria-hidden', 'true');
      indicator.append(trackProgress, percent);
      state.append(indicator);
    }
    rows.append(row);
  }
  box.replaceChildren(rows);
}
let statusRequest;
function refresh() {
  if (!statusRequest) {
    statusRequest = api('/api/status', undefined, AbortSignal.timeout(5000))
      .then(({jobs}) => {
        renderJobs(jobs);
        if (!activeJob && jobs.some(isActiveJob)) watchJob(jobs.find(isActiveJob));
        updateActiveJob(jobs);
      })
      .catch(() => {})
      .finally(() => { statusRequest = undefined; });
  }
  return statusRequest;
}
const modelButton = $('#downloadModel');
let modelBusy = false;
let modelStatusRequest;
let modelPoll;
let engineWarming = false;

function setModelReady() {
  modelButton.textContent = 'Installed ✓';
  modelButton.disabled = true;
  modelButton.previousElementSibling.querySelector('small').textContent = 'Stored on this device';
}

function showEngineStatus(state, message) {
  const element = $('#engineStatus');
  element.dataset.state = state;
  if (element.textContent !== message) element.textContent = message;
}

function renderModelStatus(model) {
  if (model.ready) setModelReady();
  else if (!modelBusy) {
    modelButton.textContent = 'Get model';
    modelButton.previousElementSibling.querySelector('small').textContent = 'Runs locally';
  }
  engineWarming = model.engine_status === 'warming';
  switch (model.engine_status) {
    case 'gpu_ready':
      showEngineStatus('ready', model.provider ? `Ready on ${model.provider}` : 'Ready');
      break;
    case 'cpu_ready':
      showEngineStatus('ready', 'Ready on CPU (slower)');
      break;
    case 'warming':
      showEngineStatus('warming', 'Warming up…');
      break;
    case 'error':
      showEngineStatus('error', model.engine_error || 'Separation is unavailable.');
      break;
    default:
      showEngineStatus('idle', model.ready ? 'Waiting to start' : 'Waiting for the model');
  }
}

function refreshModelStatus() {
  clearTimeout(modelPoll);
  if (!modelStatusRequest) {
    modelButton.disabled = true;
    modelStatusRequest = api('/api/model', undefined, AbortSignal.timeout(5000))
      .then(renderModelStatus)
      .catch(() => {
        showEngineStatus('error', engineWarming
          ? 'Could not check engine status. Retrying…'
          : 'Could not check engine status.');
      })
      .finally(() => {
        modelStatusRequest = undefined;
        if (!modelBusy && modelButton.textContent === 'Get model') modelButton.disabled = false;
        if (!modal.hidden && engineWarming) modelPoll = setTimeout(refreshModelStatus, 1500);
      });
  }
  return modelStatusRequest;
}

function openSettings() {
  modal.hidden = false;
  refreshModelStatus();
  loadOutputFolder();
}

function closeSettings() {
  modal.hidden = true;
  clearTimeout(modelPoll);
}

$('#settingsNav').onclick = openSettings;
$('#connection').onclick = openSettings;
$('#closeSettings').onclick = closeSettings;
modal.onclick = event => { if (event.target === modal) closeSettings(); };
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') closeSettings();
});

const folderInput = $('#outputFolder');
const folderMessage = $('#outputMessage');
$('#browseOutput').hidden = !window.chrome?.webview;

async function loadOutputFolder() {
  try {
    const {folder} = await api('/api/output-folder');
    if (document.activeElement !== folderInput) folderInput.value = folder;
  } catch (error) {
    folderMessage.textContent = error.message;
  }
}

async function saveOutputFolder(folder) {
  const save = $('#saveOutput');
  const browse = $('#browseOutput');
  if (save.disabled) return;
  save.disabled = browse.disabled = true;
  try {
    const result = await api('/api/output-folder', {folder});
    folderInput.value = result.folder;
    folderMessage.textContent = 'Folder saved for new tracks.';
  } catch (error) {
    folderMessage.textContent = error.message;
  } finally {
    save.disabled = browse.disabled = false;
  }
}

$('#outputFolderForm').onsubmit = event => {
  event.preventDefault();
  saveOutputFolder(folderInput.value);
};
$('#browseOutput').onclick = () => window.chrome.webview.postMessage('choose-output|' + folderInput.value);

modelButton.onclick = async () => {
  modelBusy = true;
  modelButton.disabled = true;
  modelButton.textContent = 'Preparing…';
  const message = $('#setupMessage');
  try {
    const result = await api('/api/model', {}, AbortSignal.timeout(185000));
    message.textContent = result.message;
    setModelReady();
    notify('Kim Vocal 2 model installed.');
  } catch (error) {
    message.textContent = error.name === 'TimeoutError'
      ? 'Model setup timed out. Restart Sonder and reopen Settings.'
      : error.message;
    modelButton.textContent = 'Get model';
    modelButton.disabled = false;
  } finally {
    modelBusy = false;
    if (modelStatusRequest) await modelStatusRequest;
    if (!modal.hidden) await refreshModelStatus();
  }
};
const audioPicker = $('#audioFile');
const linkInput = $('#query');
const linkButton = $('#separateLink');
let linkFetching = false;
let activeJob;
let activityPoll;
let importing = false;

function showStudioStatus(message) {
  const status = $('#studioStatus');
  if (status.textContent !== message) status.textContent = message;
}

function watchJob(job) {
  activeJob = job;
  showStudioStatus(`${job.status} · ${job.title}`);
  clearInterval(activityPoll);
  activityPoll = setInterval(refresh, 1500);
}

function updateActiveJob(jobs) {
  if (!activeJob) return;
  const job = jobs.find(item => item.id === activeJob.id);
  if (!job) return;
  if (isActiveJob(job)) {
    showStudioStatus(`${job.status} · ${job.title}`);
    return;
  }
  activeJob = undefined;
  clearInterval(activityPoll);
  if (job.error) {
    showStudioStatus(`Could not finish ${job.title}. ${job.error}`);
  } else {
    showStudioStatus(`Saved the original and both stems for ${job.title} as 320 kbps MP3.`);
    notify('Track separated successfully.');
  }
}

function setLinkFetching(active) {
  linkFetching = active;
  linkButton.disabled = active;
  linkButton.textContent = active ? 'Working…' : 'Download & separate';
}

function submitTrackLink() {
  if (linkFetching) return;
  let spotify;
  try {
    const link = new URL(linkInput.value.trim());
    if (link.origin !== 'https://open.spotify.com' || link.username || link.password ||
        !/^\/(?:intl-[a-z-]+\/)?track\/[A-Za-z0-9]{22}\/?$/i.test(link.pathname)) throw Error();
    spotify = 'https://open.spotify.com/track/' + link.pathname.replace(/\/$/, '').split('/').pop();
  } catch {
    showStudioStatus('Paste an individual Spotify track link.');
    return;
  }
  if (!window.chrome?.webview) {
    showStudioStatus('Open Sonder.exe to download links, or choose a local audio file.');
    return;
  }
  setLinkFetching(true);
  showStudioStatus('Looking up the track in SpotiSaver…');
  window.chrome.webview.postMessage('fetch-spotisaver|' + spotify);
}

$('#searchForm').onsubmit = event => {
  event.preventDefault();
  submitTrackLink();
};
linkInput.addEventListener('paste', () => setTimeout(submitTrackLink, 0));

window.chrome?.webview?.addEventListener('message', async event => {
  const message = event.data;
  if (typeof message !== 'string') return;
  if (message === 'spotisaver-imported') {
    setLinkFetching(false);
    if (statusRequest) await statusRequest;
    await refresh();
  } else if (message.startsWith('spotisaver-status|')) {
    showStudioStatus(message.slice('spotisaver-status|'.length));
  } else if (message.startsWith('spotisaver-error|')) {
    setLinkFetching(false);
    showStudioStatus(message.slice('spotisaver-error|'.length));
  } else if (message.startsWith('output-folder|')) {
    await saveOutputFolder(message.slice('output-folder|'.length));
  }
});

async function importAudio(file) {
  if (!file || importing) return;
  importing = true;
  showStudioStatus(`Importing ${file.name}…`);
  try {
    const response = await fetch('/api/audio/import?name=' + encodeURIComponent(file.name), {
      method: 'POST',
      headers: {'Content-Type': 'application/octet-stream'},
      body: file,
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.detail || 'The audio import failed.');
    if (!activeJob) watchJob(data.job);
    await refresh();
  } catch (error) {
    showStudioStatus(error.message);
  } finally {
    importing = false;
    audioPicker.value = '';
  }
}

audioPicker.onchange = () => importAudio(audioPicker.files[0]);
const dropTarget = $('#audioDrop');
dropTarget.ondragover = event => { event.preventDefault(); dropTarget.classList.add('dragging'); };
dropTarget.ondragleave = () => dropTarget.classList.remove('dragging');
dropTarget.ondrop = event => {
  event.preventDefault();
  dropTarget.classList.remove('dragging');
  importAudio(event.dataTransfer.files[0]);
};
$('#refresh').onclick = refresh;
refresh();

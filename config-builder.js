(function () {
    'use strict';

    if (!window.FileReader || !window.fetch || !window.FormData || !window.Blob) {
        return;
    }

    var form = document.getElementById('config-form');
    if (!form) return;

    var startupSection = document.getElementById('startup-section');
    var expertContainer = document.getElementById('expert-toggle-container');
    var expertToggle = document.getElementById('expert-toggle');
    var submitButton = form.querySelector('input[type="submit"]');
    var results = document.getElementById('results');

    var phase = 'initial';
    var expertMode = false;

    if (startupSection) startupSection.style.display = 'none';
    if (expertContainer) expertContainer.style.display = 'block';

    if (expertToggle) {
        expertToggle.addEventListener('click', function (ev) {
            ev.preventDefault();
            expertMode = !expertMode;
            if (expertMode) {
                expertToggle.textContent = 'Guided Mode';
                if (startupSection) startupSection.style.display = 'block';
            } else {
                expertToggle.textContent = 'Expert Mode';
                if (startupSection) {
                    startupSection.style.display = (phase === 'analyzed') ? 'block' : 'none';
                }
            }
        });
    }

    form.addEventListener('submit', async function (ev) {
        ev.preventDefault();
        clearResults();

        setBusy(true, expertMode ? 'Building...' : (phase === 'initial' ? 'Analyzing...' : 'Building...'));
        try {
            if (expertMode) {
                await doBuild();
            } else if (phase === 'initial') {
                await doAnalyze();
                phase = 'analyzed';
                if (submitButton) submitButton.value = 'Generate';
            } else {
                await doBuild();
            }
        } catch (err) {
            if (err && err.transport) {
                showError(err.message);
            }
        } finally {
            setBusy(false);
        }
    });

    function formValue(name) {
        var el = form.elements[name];
        if (!el) return '';
        if (el.type === 'checkbox') return el.checked ? '1' : '';
        return el.value || '';
    }

    function readFileInput(name) {
        return new Promise(function (resolve) {
            var el = form.elements[name];
            if (!el || !el.files || el.files.length === 0) return resolve('');
            var file = el.files[0];
            var reader = new FileReader();
            reader.onload = function () { resolve(String(reader.result || '')); };
            reader.onerror = function () { resolve(''); };
            reader.readAsText(file);
        });
    }

    async function collectInputs() {
        return {
            analog: await readFileInput('analog'),
            digital_others: await readFileInput('digitalothers'),
            digital_repeaters: await readFileInput('digitalrepeaters'),
            talkgroups: await readFileInput('talkgroups'),
            optional_settings: await readFileInput('optional_settings'),
        };
    }

    function collectOptions() {
        var multiZoneEl = form.elements['multi_zone'];
        return {
            sorting: formValue('sort'),
            hotspot_tx_permit: formValue('hotspot'),
            nicknames: formValue('nicknames'),
            multi_zone: !!(multiZoneEl && multiZoneEl.checked),
            zone_channel_sort: formValue('zone_channel_sort'),
            scanlist_channel_sort: formValue('scanlist_channel_sort'),
        };
    }

    function collectStartup() {
        return {
            zone1: formValue('start_zone1'),
            zone2: formValue('start_zone2'),
            channel1: formValue('start_channel1'),
            channel2: formValue('start_channel2'),
        };
    }

    async function postJson(payload) {
        var res;
        try {
            res = await fetch('json-endpoint.php', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload),
            });
        } catch (e) {
            var err = new Error('Network error: ' + e.message);
            err.transport = true;
            throw err;
        }

        if (!res.ok) {
            var httpErr = new Error('HTTP ' + res.status + ' ' + res.statusText);
            httpErr.transport = true;
            throw httpErr;
        }

        try {
            return await res.json();
        } catch (e) {
            var parseErr = new Error('Server returned invalid JSON');
            parseErr.transport = true;
            throw parseErr;
        }
    }

    async function doAnalyze() {
        var resp = await postJson({
            mode: 'analyze',
            inputs: await collectInputs(),
            options: collectOptions(),
        });

        if (resp.status !== 'ok') {
            showError(resp.message || 'Analyze failed');
            return;
        }

        populateStartupDropdowns(resp.zones || []);
        if (startupSection) startupSection.style.display = 'block';
        showInfo('Zones and channels discovered. Choose startup zone/channels if desired, then click Generate.');
        displayWarnings(resp.warnings);
    }

    async function doBuild() {
        var resp = await postJson({
            mode: 'build',
            inputs: await collectInputs(),
            options: collectOptions(),
            startup: collectStartup(),
        });

        if (resp.status !== 'ok') {
            showError(resp.message || 'Build failed');
            return;
        }

        displayWarnings(resp.warnings);
        displayInfoMessages(resp.info);
        displayFiles(resp.files || {});
    }

    function populateStartupDropdowns(zones) {
        var zoneMap = {};
        zones.forEach(function (z) { zoneMap[z.name] = z.channels || []; });

        ['start_zone1', 'start_zone2'].forEach(function (name) {
            replaceWithSelect(name, zones.map(function (z) { return z.name; }), '(none)');
        });

        replaceWithSelect('start_channel1', [], '(none)');
        replaceWithSelect('start_channel2', [], '(none)');

        var zone1El = form.elements['start_zone1'];
        var zone2El = form.elements['start_zone2'];
        if (zone1El) {
            zone1El.addEventListener('change', function () {
                populateChannelSelect('start_channel1', zoneMap[this.value] || []);
            });
        }
        if (zone2El) {
            zone2El.addEventListener('change', function () {
                populateChannelSelect('start_channel2', zoneMap[this.value] || []);
            });
        }
    }

    function replaceWithSelect(name, options, blankLabel) {
        var old = form.elements[name];
        if (!old) return;

        var sel = document.createElement('select');
        sel.name = name;
        if (old.id) sel.id = old.id;

        if (blankLabel !== undefined) {
            var blank = document.createElement('option');
            blank.value = '';
            blank.textContent = blankLabel;
            sel.appendChild(blank);
        }
        options.forEach(function (opt) {
            var o = document.createElement('option');
            o.value = opt;
            o.textContent = opt;
            sel.appendChild(o);
        });

        var previous = old.value;
        old.parentNode.replaceChild(sel, old);
        if (previous) {
            sel.value = previous;
            if (sel.value !== previous) sel.value = '';
        }
    }

    function populateChannelSelect(name, channels) {
        var old = form.elements[name];
        if (!old) return;

        var sel = document.createElement('select');
        sel.name = name;
        if (old.id) sel.id = old.id;

        var blank = document.createElement('option');
        blank.value = '';
        blank.textContent = '(none)';
        sel.appendChild(blank);

        channels.forEach(function (ch) {
            var o = document.createElement('option');
            o.value = ch;
            o.textContent = ch;
            sel.appendChild(o);
        });

        old.parentNode.replaceChild(sel, old);
    }

    function safeFilename(name) {
        if (typeof name !== 'string') return 'download';
        var base = name.replace(/.*[\/\\]/, '');
        base = base.replace(/[^A-Za-z0-9._-]/g, '_');
        base = base.replace(/^\.+/, '');
        return base || 'download';
    }

    function clearResults() {
        if (results) results.innerHTML = '';
    }

    function setBusy(isBusy, label) {
        if (!submitButton) return;
        submitButton.disabled = isBusy;
        if (isBusy && label) {
            submitButton.dataset.originalValue = submitButton.value;
            submitButton.value = label;
        } else if (submitButton.dataset.originalValue) {
            submitButton.value = submitButton.dataset.originalValue;
            delete submitButton.dataset.originalValue;
        }
    }

    function showError(msg) {
        appendResult('result-error', 'ERROR: ' + msg);
    }

    function showInfo(msg) {
        appendResult('result-info', msg);
    }

    function displayWarnings(warnings) {
        (warnings || []).forEach(function (w) {
            appendResult('result-warning', 'WARNING: ' + w);
        });
    }

    function displayInfoMessages(info) {
        (info || []).forEach(function (i) {
            appendResult('result-info', i);
        });
    }

    function displayFiles(files) {
        var names = Object.keys(files);
        if (names.length === 0) return;

        var container = document.createElement('div');
        container.className = 'result-success';

        var heading = document.createElement('div');
        heading.textContent = 'Your files are ready. Click each to download:';
        container.appendChild(heading);

        var list = document.createElement('ul');
        names.forEach(function (name) {
            var safeName = safeFilename(name);
            var blob = new Blob([files[name]], { type: 'text/csv' });
            var url = URL.createObjectURL(blob);

            var li = document.createElement('li');
            var a = document.createElement('a');
            a.href = url;
            a.download = safeName;
            a.textContent = name;
            li.appendChild(a);
            list.appendChild(li);

            a.addEventListener('click', function () {
                setTimeout(function () { URL.revokeObjectURL(url); }, 30000);
            });
        });

        container.appendChild(list);
        if (results) results.appendChild(container);
    }

    function appendResult(cls, text) {
        if (!results) return;
        var div = document.createElement('div');
        div.className = cls;
        div.textContent = text;
        results.appendChild(div);
    }
})();

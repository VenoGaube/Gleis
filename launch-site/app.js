(() => {
  const form = document.getElementById("waitlist-form");
  const emailInput = document.getElementById("email");
  const submitButton = document.getElementById("submit-button");
  const status = document.getElementById("form-status");

  function initializeRevealMotion() {
    const revealNodes = Array.from(document.querySelectorAll(".reveal"));
    if (revealNodes.length === 0) {
      return;
    }

    revealNodes.forEach((node) => {
      if (node.hasAttribute("data-reveal-group")) {
        Array.from(node.children).forEach((child, index) => {
          child.style.setProperty("--reveal-delay", `${index * 90}ms`);
        });
      }
    });

    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduceMotion) {
      revealNodes.forEach((node) => node.classList.add("is-visible"));
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      {
        threshold: 0.18,
        rootMargin: "0px 0px -8% 0px",
      }
    );

    revealNodes.forEach((node) => observer.observe(node));
  }

  function initializeWaitlistForm() {
    if (!form || !emailInput || !submitButton || !status) {
      return;
    }

    const configuredEndpoint = document.documentElement.dataset.signupEndpoint?.trim();

    if (configuredEndpoint) {
      form.action = configuredEndpoint;
    }

    function setStatus(message, state) {
      status.textContent = message;
      if (state) {
        status.dataset.state = state;
      } else {
        delete status.dataset.state;
      }
    }

    function isValidEmail(value) {
      return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
    }

    function hasRealEndpoint(url) {
      return url && !url.includes("REPLACE_WITH_YOUR_FORM_ID");
    }

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      setStatus("");

      const email = emailInput.value.trim();

      if (!isValidEmail(email)) {
        setStatus("Enter a valid email address.", "error");
        emailInput.focus();
        return;
      }

      if (!hasRealEndpoint(form.action)) {
        setStatus(
          "Set your signup endpoint first (replace REPLACE_WITH_YOUR_FORM_ID in index.html).",
          "error"
        );
        return;
      }

      submitButton.disabled = true;
      submitButton.textContent = "Sending...";

      const data = new FormData(form);
      data.set("email", email);
      data.set("source", "gleis-launch-site");

      try {
        const response = await fetch(form.action, {
          method: "POST",
          body: data,
          headers: {
            Accept: "application/json",
          },
        });

        if (!response.ok) {
          throw new Error("Submission failed");
        }

        form.reset();
        setStatus("You are on the list. We will email you at launch.", "success");
      } catch {
        setStatus("Could not submit right now. Try again in a moment.", "error");
      } finally {
        submitButton.disabled = false;
        submitButton.textContent = "Notify Me";
      }
    });
  }

  function initializeInteractiveDemo() {
    const demoElements = {
      clock: document.getElementById("demo-clock"),
      title: document.getElementById("screen-title"),
      subtitle: document.getElementById("screen-subtitle"),
      feedback: document.getElementById("demo-feedback"),
      simulateDelayButton: document.getElementById("simulate-delay"),
      tabButtons: Array.from(document.querySelectorAll(".app-tabs button[data-tab]")),
      panels: {
        train: document.getElementById("screen-train"),
        repeat: document.getElementById("screen-repeat"),
        settings: document.getElementById("screen-settings"),
      },
      startStation: document.getElementById("start-station"),
      endStation: document.getElementById("end-station"),
      swapStations: document.getElementById("swap-stations"),
      autoToggle: document.getElementById("auto-selection-toggle"),
      travelMinutes: document.getElementById("travel-minutes"),
      bufferMinutes: document.getElementById("buffer-minutes"),
      typeFilters: document.getElementById("train-type-filters"),
      connectionsList: document.getElementById("connections-list"),
      myJourneyCard: document.getElementById("my-journey-card"),
      trainEmpty: document.getElementById("train-empty"),
      repeatRoute: document.getElementById("repeat-route"),
      directionButtons: Array.from(document.querySelectorAll("#direction-toggle button[data-direction]")),
      repeatTime: document.getElementById("repeat-time"),
      repeatLine: document.getElementById("repeat-line"),
      weekdayGrid: document.getElementById("weekday-grid"),
      repeatSummaryText: document.getElementById("repeat-summary-text"),
      repeatAlertText: document.getElementById("repeat-alert-text"),
      notificationsEnabled: document.getElementById("notifications-enabled"),
      soundEnabled: document.getElementById("sound-enabled"),
      useDelay: document.getElementById("use-delay"),
      leadMinutes: document.getElementById("lead-minutes"),
      leadMinutesValue: document.getElementById("lead-minutes-value"),
      resetDemo: document.getElementById("reset-demo"),
    };

    const required = [
      demoElements.clock,
      demoElements.title,
      demoElements.subtitle,
      demoElements.simulateDelayButton,
      demoElements.startStation,
      demoElements.endStation,
      demoElements.swapStations,
      demoElements.autoToggle,
      demoElements.travelMinutes,
      demoElements.bufferMinutes,
      demoElements.typeFilters,
      demoElements.connectionsList,
      demoElements.myJourneyCard,
      demoElements.repeatRoute,
      demoElements.repeatTime,
      demoElements.repeatLine,
      demoElements.weekdayGrid,
      demoElements.repeatSummaryText,
      demoElements.repeatAlertText,
      demoElements.notificationsEnabled,
      demoElements.soundEnabled,
      demoElements.useDelay,
      demoElements.leadMinutes,
      demoElements.leadMinutesValue,
      demoElements.resetDemo,
    ];

    if (required.some((item) => !item)) {
      return;
    }

    const STATIONS = [
      { id: "hbf", name: "Wien Hbf" },
      { id: "meidling", name: "Wien Meidling" },
      { id: "floridsdorf", name: "Wien Floridsdorf" },
      { id: "praterstern", name: "Wien Praterstern" },
      { id: "westbahnhof", name: "Wien Westbahnhof" },
    ];

    const WEEKDAYS = [
      { id: "monday", short: "Mo" },
      { id: "tuesday", short: "Tu" },
      { id: "wednesday", short: "We" },
      { id: "thursday", short: "Th" },
      { id: "friday", short: "Fr" },
      { id: "saturday", short: "Sa" },
      { id: "sunday", short: "Su" },
    ];

    const BASE_CONNECTIONS = [
      {
        id: "c1",
        fromId: "hbf",
        toId: "meidling",
        line: "S1",
        type: "S",
        departureOffset: 7,
        duration: 10,
        delay: 0,
        platform: "5B",
        transfers: 0,
      },
      {
        id: "c2",
        fromId: "hbf",
        toId: "meidling",
        line: "REX1",
        type: "REX",
        departureOffset: 14,
        duration: 8,
        delay: 2,
        platform: "4",
        transfers: 0,
      },
      {
        id: "c3",
        fromId: "hbf",
        toId: "meidling",
        line: "RJX",
        type: "RJX",
        departureOffset: 26,
        duration: 7,
        delay: 0,
        platform: "3",
        transfers: 0,
      },
      {
        id: "c4",
        fromId: "hbf",
        toId: "praterstern",
        line: "S7",
        type: "S",
        departureOffset: 6,
        duration: 12,
        delay: 1,
        platform: "11",
        transfers: 0,
      },
      {
        id: "c5",
        fromId: "hbf",
        toId: "floridsdorf",
        line: "S1",
        type: "S",
        departureOffset: 9,
        duration: 17,
        delay: 0,
        platform: "8",
        transfers: 0,
      },
      {
        id: "c6",
        fromId: "meidling",
        toId: "hbf",
        line: "REX3",
        type: "REX",
        departureOffset: 5,
        duration: 9,
        delay: 3,
        platform: "2",
        transfers: 0,
      },
      {
        id: "c7",
        fromId: "meidling",
        toId: "westbahnhof",
        line: "U6",
        type: "U",
        departureOffset: 4,
        duration: 9,
        delay: 0,
        platform: "U6",
        transfers: 0,
      },
      {
        id: "c8",
        fromId: "praterstern",
        toId: "hbf",
        line: "S3",
        type: "S",
        departureOffset: 11,
        duration: 12,
        delay: 0,
        platform: "6",
        transfers: 0,
      },
    ];

    const defaults = {
      activeTab: "train",
      selectedStartId: "hbf",
      selectedEndId: "meidling",
      autoSelectionEnabled: true,
      travelMinutes: 12,
      bufferMinutes: 4,
      excludedTypes: [],
      pinnedConnectionId: null,
      reminderConnectionIds: [],
      repeatDirection: "toWork",
      repeatTime: "07:42",
      repeatLine: "S1",
      repeatDays: ["monday", "tuesday", "wednesday", "thursday", "friday"],
      notificationsEnabled: true,
      soundEnabled: true,
      useDelayInLeaveTime: false,
      leadMinutes: 10,
      dynamicDelayById: {},
    };

    const state = {
      ...defaults,
      excludedTypes: new Set(defaults.excludedTypes),
      reminderConnectionIds: new Set(defaults.reminderConnectionIds),
      repeatDays: new Set(defaults.repeatDays),
      dynamicDelayById: { ...defaults.dynamicDelayById },
    };

    function resetDemoState() {
      state.activeTab = defaults.activeTab;
      state.selectedStartId = defaults.selectedStartId;
      state.selectedEndId = defaults.selectedEndId;
      state.autoSelectionEnabled = defaults.autoSelectionEnabled;
      state.travelMinutes = defaults.travelMinutes;
      state.bufferMinutes = defaults.bufferMinutes;
      state.excludedTypes = new Set(defaults.excludedTypes);
      state.pinnedConnectionId = defaults.pinnedConnectionId;
      state.reminderConnectionIds = new Set(defaults.reminderConnectionIds);
      state.repeatDirection = defaults.repeatDirection;
      state.repeatTime = defaults.repeatTime;
      state.repeatLine = defaults.repeatLine;
      state.repeatDays = new Set(defaults.repeatDays);
      state.notificationsEnabled = defaults.notificationsEnabled;
      state.soundEnabled = defaults.soundEnabled;
      state.useDelayInLeaveTime = defaults.useDelayInLeaveTime;
      state.leadMinutes = defaults.leadMinutes;
      state.dynamicDelayById = { ...defaults.dynamicDelayById };
    }

    function stationName(stationId) {
      return STATIONS.find((station) => station.id === stationId)?.name || "Unknown";
    }

    function lineClass(type) {
      return type.toLowerCase().replace(/[^a-z0-9]+/g, "");
    }

    function formatClock(date) {
      return new Intl.DateTimeFormat("en-GB", {
        hour: "2-digit",
        minute: "2-digit",
      }).format(date);
    }

    function formatCountdown(totalMinutes) {
      if (totalMinutes <= 0) {
        return "Leave now";
      }
      if (totalMinutes < 60) {
        return `${totalMinutes}m`;
      }
      const hours = Math.floor(totalMinutes / 60);
      const minutes = totalMinutes % 60;
      if (minutes === 0) {
        return `${hours}h`;
      }
      return `${hours}h ${minutes}m`;
    }

    function urgencyClass(minutes) {
      if (minutes <= 2) {
        return "urgent";
      }
      if (minutes <= 6) {
        return "warn";
      }
      return "";
    }

    function effectiveDelayFor(connection) {
      return (state.dynamicDelayById[connection.id] ?? 0) + connection.delay;
    }

    function routeConnections() {
      return BASE_CONNECTIONS.filter((connection) => {
        return connection.fromId === state.selectedStartId && connection.toId === state.selectedEndId;
      });
    }

    function renderedConnections() {
      const now = Date.now();
      return routeConnections().map((connection) => {
        const delay = effectiveDelayFor(connection);
        const departure = new Date(now + connection.departureOffset * 60000);
        const arrival = new Date(departure.getTime() + connection.duration * 60000);
        const effectiveDeparture = state.useDelayInLeaveTime
          ? new Date(departure.getTime() + delay * 60000)
          : departure;
        const leaveAt = new Date(
          effectiveDeparture.getTime() - (state.travelMinutes + state.bufferMinutes) * 60000
        );
        const leaveInMinutes = Math.ceil((leaveAt.getTime() - now) / 60000);
        return {
          ...connection,
          delay,
          departure,
          arrival,
          leaveAt,
          leaveInMinutes,
        };
      });
    }

    function updateClock() {
      const now = new Date();
      demoElements.clock.textContent = formatClock(now);
    }

    function setFeedback(message) {
      if (demoElements.feedback) {
        demoElements.feedback.textContent = message;
      }
    }

    function renderTabState() {
      const subtitles = {
        train: "Pick a route and test live commute cards.",
        repeat: "Build weekday schedules for your regular journey.",
        settings: "Control reminders and leave-time behavior.",
      };

      demoElements.title.textContent =
        state.activeTab === "train" ? "Train" : state.activeTab === "repeat" ? "Repeat Journeys" : "Settings";
      demoElements.subtitle.textContent = subtitles[state.activeTab];

      demoElements.tabButtons.forEach((button) => {
        const isActive = button.dataset.tab === state.activeTab;
        button.classList.toggle("is-active", isActive);
      });

      Object.entries(demoElements.panels).forEach(([name, panel]) => {
        if (panel) {
          panel.classList.toggle("is-active", name === state.activeTab);
        }
      });

      const showSimulate = state.activeTab === "train";
      demoElements.simulateDelayButton.hidden = !showSimulate;
    }

    function populateStations() {
      const options = STATIONS.map((station) => {
        return `<option value="${station.id}">${station.name}</option>`;
      }).join("");

      demoElements.startStation.innerHTML = options;
      demoElements.endStation.innerHTML = options;

      demoElements.startStation.value = state.selectedStartId;
      demoElements.endStation.value = state.selectedEndId;
    }

    function renderTypeFilters(connections) {
      const availableTypes = [...new Set(connections.map((connection) => connection.type))];

      if (availableTypes.length === 0) {
        demoElements.typeFilters.innerHTML = "";
        return;
      }

      demoElements.typeFilters.innerHTML = availableTypes
        .map((type) => {
          const active = !state.excludedTypes.has(type);
          return `<button type="button" class="type-chip ${active ? "is-active" : ""}" data-type="${type}">${type}</button>`;
        })
        .join("");
    }

    function renderMyJourney(connections) {
      const pinnedConnection = connections.find((connection) => connection.id === state.pinnedConnectionId);
      if (!pinnedConnection) {
        demoElements.myJourneyCard.hidden = true;
        demoElements.myJourneyCard.innerHTML = "";
        return;
      }

      demoElements.myJourneyCard.hidden = false;
      demoElements.myJourneyCard.innerHTML = `
        <h4>My Journey</h4>
        <p>${stationName(state.selectedStartId)} -> ${stationName(state.selectedEndId)}</p>
        <p class="muted">${pinnedConnection.line} | Departs ${formatClock(
        pinnedConnection.departure
      )} | Platform ${pinnedConnection.platform}</p>
        <button type="button" data-action="unpin" data-id="${pinnedConnection.id}">Unpin</button>
      `;
    }

    function renderConnections() {
      const connections = renderedConnections();
      const visibleConnections = connections.filter((connection) => !state.excludedTypes.has(connection.type));

      renderTypeFilters(connections);
      renderMyJourney(connections);

      if (visibleConnections.length === 0) {
        demoElements.connectionsList.innerHTML = "";
        demoElements.trainEmpty.hidden = false;
        return;
      }

      demoElements.trainEmpty.hidden = true;

      demoElements.connectionsList.innerHTML = visibleConnections
        .map((connection) => {
          const reminderOn = state.reminderConnectionIds.has(connection.id);
          const pinned = state.pinnedConnectionId === connection.id;
          const leaveClass = urgencyClass(connection.leaveInMinutes);
          const reminderDisabled = !state.notificationsEnabled;

          return `
            <article class="connection-card">
              <div class="connection-head">
                <div>
                  <span class="line-pill ${lineClass(connection.type)}">${connection.line}</span>
                  <p class="connection-route">${stationName(connection.fromId)} -> ${stationName(connection.toId)}</p>
                  <p class="connection-sub">${connection.duration} min | ${connection.transfers} transfers</p>
                </div>
                ${
                  connection.delay > 0
                    ? `<span class="delay-pill">+${connection.delay} min</span>`
                    : ""
                }
              </div>

              <div class="time-grid">
                <div class="time-block">
                  <small>Departs</small>
                  <strong>${formatClock(connection.departure)}</strong>
                </div>
                <span class="time-arrow">-></span>
                <div class="time-block">
                  <small>Arrives</small>
                  <strong>${formatClock(connection.arrival)}</strong>
                </div>
                <span class="platform">${connection.platform}</span>
              </div>

              <div class="leave-row">
                <div>
                  <small>Leave at</small>
                  <strong>${formatClock(connection.leaveAt)} (${formatCountdown(connection.leaveInMinutes)})</strong>
                </div>
                <span class="leave-chip ${leaveClass}">${connection.leaveInMinutes <= 0 ? "Go" : "On Track"}</span>
              </div>

              <div class="card-actions">
                <button type="button" class="${pinned ? "is-active" : ""}" data-action="pin" data-id="${
            connection.id
          }">${pinned ? "Pinned" : "Pin"}</button>
                <button type="button" class="${reminderOn ? "is-active" : ""}" data-action="reminder" data-id="${
            connection.id
          }" ${reminderDisabled ? "disabled" : ""}>${reminderOn ? "Reminder On" : "Set Reminder"}</button>
              </div>
            </article>
          `;
        })
        .join("");
    }

    function populateRepeatLineOptions() {
      const allLines = [...new Set(BASE_CONNECTIONS.map((connection) => connection.line))].sort();
      demoElements.repeatLine.innerHTML = allLines
        .map((line) => `<option value="${line}">${line}</option>`)
        .join("");
      demoElements.repeatLine.value = state.repeatLine;
    }

    function renderWeekdayButtons() {
      demoElements.weekdayGrid.innerHTML = WEEKDAYS.map((weekday) => {
        const active = state.repeatDays.has(weekday.id);
        return `<button type="button" class="${active ? "is-active" : ""}" data-day="${weekday.id}">${weekday.short}</button>`;
      }).join("");
    }

    function renderRepeatScreen() {
      demoElements.repeatRoute.textContent =
        state.repeatDirection === "toWork"
          ? `${stationName(state.selectedStartId)} -> ${stationName(state.selectedEndId)}`
          : `${stationName(state.selectedEndId)} -> ${stationName(state.selectedStartId)}`;

      demoElements.directionButtons.forEach((button) => {
        button.classList.toggle("is-active", button.dataset.direction === state.repeatDirection);
      });

      demoElements.repeatTime.value = state.repeatTime;
      demoElements.repeatLine.value = state.repeatLine;
      renderWeekdayButtons();

      const selectedDays = WEEKDAYS.filter((weekday) => state.repeatDays.has(weekday.id)).map(
        (weekday) => weekday.short
      );

      const [hour, minute] = state.repeatTime.split(":").map(Number);
      const departureDate = new Date();
      departureDate.setHours(hour, minute, 0, 0);
      const leaveTime = new Date(
        departureDate.getTime() -
          (state.travelMinutes + state.bufferMinutes + state.leadMinutes) * 60000
      );

      demoElements.repeatSummaryText.textContent =
        selectedDays.length > 0
          ? `${state.repeatLine} at ${state.repeatTime} on ${selectedDays.join(", ")}`
          : "Select at least one active day.";

      demoElements.repeatAlertText.textContent =
        selectedDays.length > 0
          ? `Reminder target: ${formatClock(leaveTime)} (${state.leadMinutes} min lead + walk/buffer)`
          : "No reminders scheduled until you select days.";
    }

    function renderSettings() {
      demoElements.notificationsEnabled.checked = state.notificationsEnabled;
      demoElements.soundEnabled.checked = state.soundEnabled;
      demoElements.useDelay.checked = state.useDelayInLeaveTime;
      demoElements.leadMinutes.value = String(state.leadMinutes);
      demoElements.leadMinutesValue.textContent = `${state.leadMinutes} min`;

      demoElements.soundEnabled.disabled = !state.notificationsEnabled;
      demoElements.autoToggle.classList.toggle("is-off", !state.autoSelectionEnabled);
      demoElements.autoToggle.textContent = state.autoSelectionEnabled ? "Auto On" : "Auto Off";
      demoElements.autoToggle.setAttribute("aria-pressed", state.autoSelectionEnabled ? "true" : "false");
    }

    function renderDemo() {
      renderTabState();
      renderConnections();
      renderRepeatScreen();
      renderSettings();
      demoElements.startStation.value = state.selectedStartId;
      demoElements.endStation.value = state.selectedEndId;
      demoElements.travelMinutes.value = String(state.travelMinutes);
      demoElements.bufferMinutes.value = String(state.bufferMinutes);
    }

    function toggleTypeFilter(type) {
      if (state.excludedTypes.has(type)) {
        state.excludedTypes.delete(type);
      } else {
        state.excludedTypes.add(type);
      }
      renderConnections();
    }

    function attachEvents() {
      demoElements.tabButtons.forEach((button) => {
        button.addEventListener("click", () => {
          state.activeTab = button.dataset.tab || "train";
          renderDemo();
        });
      });

      demoElements.startStation.addEventListener("change", () => {
        state.selectedStartId = demoElements.startStation.value;
        if (state.selectedStartId === state.selectedEndId) {
          setFeedback("Origin and destination cannot be the same.");
        } else {
          setFeedback("Route updated.");
        }
        state.pinnedConnectionId = null;
        state.reminderConnectionIds.clear();
        renderDemo();
      });

      demoElements.endStation.addEventListener("change", () => {
        state.selectedEndId = demoElements.endStation.value;
        if (state.selectedStartId === state.selectedEndId) {
          setFeedback("Origin and destination cannot be the same.");
        } else {
          setFeedback("Route updated.");
        }
        state.pinnedConnectionId = null;
        state.reminderConnectionIds.clear();
        renderDemo();
      });

      demoElements.swapStations.addEventListener("click", () => {
        const prevStart = state.selectedStartId;
        state.selectedStartId = state.selectedEndId;
        state.selectedEndId = prevStart;
        state.pinnedConnectionId = null;
        state.reminderConnectionIds.clear();
        setFeedback("Direction switched.");
        renderDemo();
      });

      demoElements.autoToggle.addEventListener("click", () => {
        state.autoSelectionEnabled = !state.autoSelectionEnabled;
        setFeedback(state.autoSelectionEnabled ? "Auto-selection enabled." : "Auto-selection paused.");
        renderSettings();
      });

      demoElements.travelMinutes.addEventListener("change", () => {
        const value = Number(demoElements.travelMinutes.value);
        state.travelMinutes = Number.isFinite(value) ? Math.min(40, Math.max(1, value)) : state.travelMinutes;
        renderDemo();
      });

      demoElements.bufferMinutes.addEventListener("change", () => {
        const value = Number(demoElements.bufferMinutes.value);
        state.bufferMinutes = Number.isFinite(value) ? Math.min(20, Math.max(0, value)) : state.bufferMinutes;
        renderDemo();
      });

      demoElements.typeFilters.addEventListener("click", (event) => {
        const button = event.target.closest("button[data-type]");
        if (!button) {
          return;
        }
        toggleTypeFilter(button.dataset.type || "");
      });

      demoElements.connectionsList.addEventListener("click", (event) => {
        const button = event.target.closest("button[data-action]");
        if (!button) {
          return;
        }

        const action = button.dataset.action;
        const id = button.dataset.id;
        if (!action || !id) {
          return;
        }

        if (action === "pin") {
          state.pinnedConnectionId = state.pinnedConnectionId === id ? null : id;
          setFeedback(state.pinnedConnectionId ? "Journey pinned." : "Journey unpinned.");
        }

        if (action === "reminder") {
          if (!state.notificationsEnabled) {
            setFeedback("Enable notifications in Settings first.");
            return;
          }
          if (state.reminderConnectionIds.has(id)) {
            state.reminderConnectionIds.delete(id);
            setFeedback("Reminder cancelled.");
          } else {
            state.reminderConnectionIds.add(id);
            setFeedback("Reminder set.");
          }
        }

        renderConnections();
      });

      demoElements.myJourneyCard.addEventListener("click", (event) => {
        const button = event.target.closest("button[data-action='unpin']");
        if (!button) {
          return;
        }
        state.pinnedConnectionId = null;
        setFeedback("Journey unpinned.");
        renderConnections();
      });

      demoElements.directionButtons.forEach((button) => {
        button.addEventListener("click", () => {
          state.repeatDirection = button.dataset.direction || "toWork";
          renderRepeatScreen();
        });
      });

      demoElements.repeatTime.addEventListener("change", () => {
        state.repeatTime = demoElements.repeatTime.value;
        renderRepeatScreen();
      });

      demoElements.repeatLine.addEventListener("change", () => {
        state.repeatLine = demoElements.repeatLine.value;
        renderRepeatScreen();
      });

      demoElements.weekdayGrid.addEventListener("click", (event) => {
        const button = event.target.closest("button[data-day]");
        if (!button) {
          return;
        }
        const day = button.dataset.day;
        if (!day) {
          return;
        }
        if (state.repeatDays.has(day)) {
          state.repeatDays.delete(day);
        } else {
          state.repeatDays.add(day);
        }
        renderRepeatScreen();
      });

      demoElements.notificationsEnabled.addEventListener("change", () => {
        state.notificationsEnabled = demoElements.notificationsEnabled.checked;
        if (!state.notificationsEnabled) {
          state.reminderConnectionIds.clear();
        }
        renderDemo();
      });

      demoElements.soundEnabled.addEventListener("change", () => {
        state.soundEnabled = demoElements.soundEnabled.checked;
      });

      demoElements.useDelay.addEventListener("change", () => {
        state.useDelayInLeaveTime = demoElements.useDelay.checked;
        setFeedback(state.useDelayInLeaveTime ? "Delay-aware leave time enabled." : "Delay-aware leave time off.");
        renderDemo();
      });

      demoElements.leadMinutes.addEventListener("input", () => {
        state.leadMinutes = Number(demoElements.leadMinutes.value);
        renderSettings();
        renderRepeatScreen();
      });

      demoElements.resetDemo.addEventListener("click", () => {
        resetDemoState();
        setFeedback("Demo reset to defaults.");
        renderDemo();
      });

      demoElements.simulateDelayButton.addEventListener("click", () => {
        const candidates = routeConnections();
        if (candidates.length === 0) {
          setFeedback("No route selected to simulate delay.");
          return;
        }

        const firstConnection = candidates[0];
        state.dynamicDelayById[firstConnection.id] = (state.dynamicDelayById[firstConnection.id] || 0) + 2;
        setFeedback(`${firstConnection.line} updated with +2 min delay.`);
        renderConnections();
      });
    }

    populateStations();
    populateRepeatLineOptions();
    attachEvents();
    renderDemo();
    updateClock();
    window.setInterval(updateClock, 15000);
    window.setInterval(renderConnections, 30000);
  }

  initializeRevealMotion();
  initializeWaitlistForm();
  initializeInteractiveDemo();
})();

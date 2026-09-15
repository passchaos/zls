export function normalizeChannelName(value) {
  return value.trim().toLowerCase().replace(/\s+/g, "-").replace(/[^a-z0-9-]/g, "").replace(/-+/g, "-").replace(/^-|-$/g, "");
}

export function filterMessages(messages, query) {
  const needle = query.trim().toLowerCase();
  return messages.map((message) => !needle || message.toLowerCase().includes(needle));
}

export function nextReactionCount(count, active) {
  return Math.max(0, count + (active ? -1 : 1));
}

export function visibleMemberCount(expanded, total, previewCount = 4) {
  return expanded ? total : Math.min(total, previewCount);
}

export function applyInlineMarkup(value, start, end, format) {
  const selection = value.slice(start, end);
  const formats = {
    bold: ["**", "**", "bold text"],
    italic: ["_", "_", "italic text"],
    link: ["[", "](https://)", "link text"],
    list: ["- ", "", "list item"],
  };
  const [before, after, placeholder] = formats[format] ?? ["", "", ""];
  const content = selection || placeholder;
  return {
    value: value.slice(0, start) + before + content + after + value.slice(end),
    selectionStart: start + before.length,
    selectionEnd: start + before.length + content.length,
  };
}

export function buildOutgoingMessage(value, filename = "") {
  const message = value.trim();
  const attachment = filename ? `📎 ${filename}` : "";
  return [message, attachment].filter(Boolean).join("\n");
}

function boot() {
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
  const toast = $("#toast");
  let toastTimer;
  const showToast = (message) => {
    toast.textContent = message;
    toast.classList.add("visible");
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => toast.classList.remove("visible"), 2200);
  };

  const refreshIcons = () => window.lucide?.createIcons({ attrs: { "stroke-width": 1.8 } });
  window.addEventListener("load", refreshIcons);

  const workspaceSwitcher = $("#workspaceSwitcher");
  const workspaceMenu = $("#workspaceMenu");
  workspaceSwitcher.addEventListener("click", () => {
    const isOpen = workspaceMenu.hidden;
    workspaceMenu.hidden = !isOpen;
    workspaceSwitcher.setAttribute("aria-expanded", String(isOpen));
  });

  const channelTitle = $("#channelTitle");
  const channelSubtitle = $("#channelSubtitle");
  const messageList = $("#messageList");
  const messageStage = $("#messageStage");
  const conversationEmpty = $("#conversationEmpty");
  const messageInput = $("#messageInput");
  const fileInput = $("#fileInput");
  const attachmentName = $("#attachmentName");
  const memberCountValue = $("#memberCountValue");
  const memberTotal = $("#memberTotal");
  const titleHash = $(".title-hash");
  const detailsTitle = $("#detailsTitle");
  const detailDescription = $("#detailDescription");
  const topicValue = $("#topicValue");
  let activeConversation = "product";
  const conversationNodes = new Map([[activeConversation, [...messageList.childNodes]]]);
  const descriptions = {
    announcements: "Company-wide updates and important news.",
    design: "Critiques, explorations, and design system work.",
    product: "Planning, decisions, and product momentum.",
    random: "The place for everything outside the roadmap.",
  };
  const topics = {
    announcements: "Company updates",
    design: "Design system review",
    product: "Q4 onboarding refresh",
    random: "Off-topic conversation",
  };
  const conversationLabel = () => activeConversation.startsWith("dm:") ? channelTitle.textContent : `#${channelTitle.textContent}`;

  $("#channelList").addEventListener("click", (event) => {
    const row = event.target.closest("[data-channel]");
    if (!row) return;
    closeSearch();
    $$(".channel-row").forEach((item) => { item.classList.remove("selected"); item.removeAttribute("aria-current"); });
    row.classList.add("selected");
    row.setAttribute("aria-current", "page");
    row.classList.remove("unread");
    row.querySelector(".unread-dot")?.remove();
    conversationNodes.set(activeConversation, [...messageList.childNodes]);
    $$("[data-dm]").forEach((item) => { item.classList.remove("selected"); item.removeAttribute("aria-current"); });
    const channel = row.dataset.channel;
    activeConversation = channel;
    titleHash.hidden = false;
    channelTitle.textContent = channel;
    channelSubtitle.textContent = descriptions[channel] ?? "Team conversation.";
    messageStage.setAttribute("aria-label", `Messages in ${channel}`);
    detailsTitle.textContent = "Channel details";
    detailDescription.textContent = descriptions[channel] ?? "A focused place for team conversation.";
    topicValue.textContent = topics[channel] ?? "New channel";
    messageInput.placeholder = `Message #${channel}`;
    messageInput.setAttribute("aria-label", `Message ${channel}`);
    memberCountValue.textContent = row.dataset.members ?? "0";
    memberTotal.textContent = row.dataset.members ?? "0";
    const nodes = conversationNodes.get(channel) ?? [];
    messageList.replaceChildren(...nodes);
    messageList.hidden = nodes.length === 0;
    conversationEmpty.hidden = nodes.length !== 0;
    if (nodes.length === 0) $("#emptyTitle").textContent = `#${channel} is quiet`;
    setThreadOpen(false);
    syncMuteButton();
  });

  $$("[data-dm]").forEach((row) => row.addEventListener("click", () => {
    closeSearch();
    conversationNodes.set(activeConversation, [...messageList.childNodes]);
    $$(".channel-row").forEach((item) => { item.classList.remove("selected"); item.removeAttribute("aria-current"); });
    $$("[data-dm]").forEach((item) => { item.classList.remove("selected"); item.removeAttribute("aria-current"); });
    row.classList.add("selected");
    row.setAttribute("aria-current", "page");
    row.classList.remove("unread");
    row.querySelector(".unread-badge")?.remove();
    activeConversation = `dm:${row.dataset.dm}`;
    titleHash.hidden = true;
    channelTitle.textContent = row.dataset.dm;
    channelSubtitle.textContent = "Direct message";
    messageStage.setAttribute("aria-label", `Messages with ${row.dataset.dm}`);
    detailsTitle.textContent = "Conversation details";
    detailDescription.textContent = `A private conversation between you and ${row.dataset.dm}.`;
    topicValue.textContent = "Direct message";
    memberCountValue.textContent = "2";
    memberTotal.textContent = "2";
    messageInput.placeholder = `Message ${row.dataset.dm}`;
    messageInput.setAttribute("aria-label", `Message ${row.dataset.dm}`);
    const nodes = conversationNodes.get(activeConversation) ?? [];
    messageList.replaceChildren(...nodes);
    messageList.hidden = nodes.length === 0;
    conversationEmpty.hidden = nodes.length !== 0;
    if (nodes.length === 0) $("#emptyTitle").textContent = `Start a conversation with ${row.dataset.dm}`;
    setThreadOpen(false);
    syncMuteButton();
  }));

  const searchBar = $("#searchBar");
  const searchInput = $("#searchInput");
  const searchCount = $("#searchCount");
  const closeSearch = () => {
    searchBar.hidden = true;
    searchInput.value = "";
    messageList.classList.remove("searching");
    $$(".message-row").forEach((row) => { row.hidden = false; });
  };
  $("#searchButton").addEventListener("click", () => {
    searchBar.hidden = false;
    const count = $$(".message-row", messageList).length;
    searchCount.textContent = `${count} ${count === 1 ? "message" : "messages"}`;
    searchInput.placeholder = `Search in ${conversationLabel()}`;
    searchInput.focus();
  });
  $("#closeSearch").addEventListener("click", closeSearch);
  searchInput.addEventListener("input", () => {
    messageList.classList.toggle("searching", Boolean(searchInput.value.trim()));
    const rows = $$(".message-row");
    const visible = filterMessages(rows.map((row) => row.dataset.search ?? row.textContent), searchInput.value);
    let count = 0;
    rows.forEach((row, index) => { row.hidden = !visible[index]; if (visible[index]) count += 1; });
    searchCount.textContent = `${count} ${count === 1 ? "message" : "messages"}`;
  });

  const muteButton = $("#muteButton");
  const mutedConversations = new Set();
  const syncMuteButton = () => {
    const muted = mutedConversations.has(activeConversation);
    muteButton.setAttribute("aria-pressed", String(muted));
    muteButton.classList.toggle("active", muted);
    const action = muted ? "Unmute" : "Mute";
    muteButton.title = `${action} ${conversationLabel()}`;
    muteButton.setAttribute("aria-label", `${action} ${conversationLabel()}`);
  };
  muteButton.addEventListener("click", () => {
    const muted = !mutedConversations.has(activeConversation);
    if (muted) mutedConversations.add(activeConversation);
    else mutedConversations.delete(activeConversation);
    syncMuteButton();
    showToast(muted ? `Muted ${conversationLabel()}` : `Notifications on for ${conversationLabel()}`);
  });

  const videoButton = $("#videoButton");
  videoButton.addEventListener("click", () => {
    const active = videoButton.getAttribute("aria-pressed") !== "true";
    videoButton.setAttribute("aria-pressed", String(active));
    videoButton.querySelector("span").textContent = active ? "Leave video call" : "Start video call";
    showToast(active ? "Video room started" : "You left the video room");
  });

  const threadPanel = $("#threadPanel");
  const setThreadOpen = (open) => {
    threadPanel.classList.toggle("open", open);
    threadPanel.setAttribute("aria-hidden", String(!open));
    threadPanel.inert = !open;
  };
  messageList.addEventListener("click", (event) => {
    if (event.target.closest("#openThread")) setThreadOpen(true);
    const reaction = event.target.closest(".reaction-chip");
    if (!reaction) return;
    const active = reaction.classList.contains("active");
    const countNode = reaction.querySelector(".reaction-count");
    countNode.textContent = String(nextReactionCount(Number(countNode.textContent), active));
    reaction.classList.toggle("active", !active);
    reaction.setAttribute("aria-pressed", String(!active));
    reaction.title = active ? "Add reaction" : "Remove reaction";
  });
  $("#closeThread").addEventListener("click", () => setThreadOpen(false));

  const membersToggle = $("#membersToggle");
  const memberList = $("#memberList");
  membersToggle.addEventListener("click", () => {
    const expanded = membersToggle.getAttribute("aria-expanded") !== "true";
    membersToggle.setAttribute("aria-expanded", String(expanded));
    memberList.hidden = !expanded;
    const icon = membersToggle.querySelector("svg");
    if (icon) icon.outerHTML = `<i data-lucide="${expanded ? "chevron-up" : "chevron-down"}" aria-hidden="true"></i>`;
    refreshIcons();
  });

  $("#memberCount").addEventListener("click", () => {
    $(".members-section").scrollIntoView({ behavior: "smooth", block: "start" });
    $(".details-panel").classList.add("attention");
    window.setTimeout(() => $(".details-panel").classList.remove("attention"), 700);
  });

  const viewAllMembers = $("#viewAllMembers");
  let allMembersVisible = false;
  viewAllMembers.addEventListener("click", () => {
    allMembersVisible = !allMembersVisible;
    $$(".extra-member").forEach((member) => { member.hidden = !allMembersVisible; });
    viewAllMembers.textContent = allMembersVisible ? "Show fewer members" : "View all members";
  });

  const appendOwnMessage = (target, text) => {
    const article = document.createElement("article");
    article.className = target === messageList ? "message-row" : "thread-message";
    article.dataset.search = `jordan lee now ${text}`.toLowerCase();
    article.innerHTML = `<span class="avatar avatar-jordan">JL</span><div class="message-body"><div class="message-meta"><strong>Jordan Lee</strong><time>now</time></div><p></p></div>`;
    article.querySelector("p").textContent = text;
    target.append(article);
    article.scrollIntoView({ block: "nearest" });
  };

  $("#messageForm").addEventListener("submit", (event) => {
    event.preventDefault();
    const text = buildOutgoingMessage(messageInput.value, fileInput.files?.[0]?.name);
    if (!text) return;
    appendOwnMessage(messageList, text);
    messageList.hidden = false;
    conversationEmpty.hidden = true;
    messageInput.value = "";
    fileInput.value = "";
    attachmentName.textContent = "";
  });
  messageInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); $("#messageForm").requestSubmit(); }
  });

  $("#replyForm").addEventListener("submit", (event) => {
    event.preventDefault();
    const input = $("#replyInput");
    const replyFileInput = $("#replyFileInput");
    const text = buildOutgoingMessage(input.value, replyFileInput.files?.[0]?.name);
    if (!text) return;
    appendOwnMessage($("#threadReplies"), text);
    input.value = "";
    replyFileInput.value = "";
    $("#replyAttachmentName").textContent = "";
  });
  $("#replyInput").addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); $("#replyForm").requestSubmit(); }
  });

  $("#attachButton").addEventListener("click", () => fileInput.click());
  $("#fileInput").addEventListener("change", (event) => {
    attachmentName.textContent = event.target.files?.[0]?.name ?? "";
  });
  $("#emojiButton").addEventListener("click", () => { messageInput.value += " 👍"; messageInput.focus(); });
  $("#replyAttachButton").addEventListener("click", () => $("#replyFileInput").click());
  $("#replyFileInput").addEventListener("change", (event) => {
    $("#replyAttachmentName").textContent = event.target.files?.[0]?.name ?? "";
  });
  $("#replyEmojiButton").addEventListener("click", () => {
    const input = $("#replyInput");
    input.value += " 👍";
    input.focus();
  });
  $$("[data-format]").forEach((button) => button.addEventListener("click", () => {
    const result = applyInlineMarkup(messageInput.value, messageInput.selectionStart, messageInput.selectionEnd, button.dataset.format);
    messageInput.value = result.value;
    messageInput.focus();
    messageInput.setSelectionRange(result.selectionStart, result.selectionEnd);
  }));
  $(".file-card").addEventListener("click", () => showToast("Opening release-checklist.pdf"));

  const dialog = $("#channelDialog");
  $("#addChannelButton").addEventListener("click", () => dialog.showModal());
  $("#newMessageButton").addEventListener("click", () => { messageInput.focus(); showToast("Ready for a new message"); });
  $("#cancelChannel").addEventListener("click", () => dialog.close());
  $("#channelNameInput").addEventListener("input", (event) => { event.target.value = normalizeChannelName(event.target.value); });
  $("#channelForm").addEventListener("submit", (event) => {
    event.preventDefault();
    const input = $("#channelNameInput");
    const name = normalizeChannelName(input.value);
    if (!name) return;
    const row = document.createElement("button");
    row.className = "channel-row";
    row.type = "button";
    row.dataset.channel = name;
    row.dataset.members = "1";
    row.innerHTML = `<span class="hash">#</span><span class="channel-name"></span>`;
    row.querySelector(".channel-name").textContent = name;
    $("#channelList").append(row);
    input.value = "";
    dialog.close();
    showToast(`#${name} created`);
  });

  $$(".workspace-menu button").forEach((button) => button.addEventListener("click", () => {
    workspaceMenu.hidden = true;
    workspaceSwitcher.setAttribute("aria-expanded", "false");
    showToast(`${button.textContent} opened`);
  }));
  $(".profile-card .icon-button").addEventListener("click", () => showToast("Profile settings opened"));
  $(".nav-section[aria-labelledby='dmLabel'] .icon-button").addEventListener("click", () => showToast("New direct message"));
  $("#channelOptionsButton").addEventListener("click", () => showToast(`More options for ${conversationLabel()}`));
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    closeSearch();
    setThreadOpen(false);
    workspaceMenu.hidden = true;
    workspaceSwitcher.setAttribute("aria-expanded", "false");
  });
}

if (typeof document !== "undefined") boot();

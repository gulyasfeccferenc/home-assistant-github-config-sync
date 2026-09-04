#!/usr/bin/with-contenv bashio

set -uo pipefail

REPO="/config"

REMOTE="$(bashio::config 'remote')"
BRANCH="$(bashio::config 'branch')"
POLL_INTERVAL="$(bashio::config 'poll_interval')"
LOCAL_SETTLE_SECONDS="$(bashio::config 'local_settle_seconds')"
AUTO_RELOAD="$(bashio::config 'auto_reload')"
DRY_RUN="$(bashio::config 'dry_run')"

export GIT_TERMINAL_PROMPT=0

DIRTY_SIGNATURE=""
DIRTY_SINCE=0

log_state() {
    bashio::log.info "$1"
}

notify_issue() {
    local title="$1"
    local message="$2"
    local payload

    payload="$(
        jq -n \
            --arg title "$title" \
            --arg message "$message" \
            '{
                title: $title,
                message: $message,
                notification_id: "ha_config_sync_issue"
            }'
    )"

    curl -fsS \
        -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "http://supervisor/core/api/services/persistent_notification/create" \
        >/dev/null 2>&1 || true
}

dismiss_issue() {
    curl -fsS \
        -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"notification_id":"ha_config_sync_issue"}' \
        "http://supervisor/core/api/services/persistent_notification/dismiss" \
        >/dev/null 2>&1 || true
}

check_config() {
    local response_file="/tmp/ha_config_check.json"
    local status

    status="$(
        curl -sS \
            -o "${response_file}" \
            -w '%{http_code}' \
            -X POST \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/core/check"
    )"

    if [ "${status}" -ge 200 ] && [ "${status}" -lt 300 ]; then
        if jq -e '.result == "ok"' "${response_file}" >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

reload_config() {
    curl -fsS \
        -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{}' \
        "http://supervisor/core/api/services/homeassistant/reload_all" \
        >/dev/null
}

get_dirty_signature() {
    {
        git diff --no-ext-diff --binary

        git ls-files --others --exclude-standard | sort | while read -r file; do
            printf '%s\n' "${file}"

            if [ -f "${file}" ]; then
                sha256sum "${file}" 2>/dev/null || true
            fi
        done
    } | sha256sum | awk '{print $1}'
}

scan_staged_secrets() {
    local suspicious_files=""
    local file

    while IFS= read -r file; do
        [ -z "${file}" ] && continue

        if git diff \
            --cached \
            --unified=0 \
            --no-color \
            -- "${file}" \
            | sed -n 's/^+//p' \
            | grep -Ei \
                '(access_token[[:space:]]*:|[?&]token=|password[[:space:]]*:|passwd[[:space:]]*:|api[_-]?key[[:space:]]*:|auth[_-]?token[[:space:]]*:|client[_-]?secret[[:space:]]*:|authorization[[:space:]]*:|bearer[[:space:]]+[A-Za-z0-9._-]{12,}|encryption[_-]?key[[:space:]]*:|private[_-]?key[[:space:]]*:)' \
            | grep -Ev \
                ':[[:space:]]*!secret([[:space:]]|$)' \
            >/dev/null 2>&1
        then
            suspicious_files="${suspicious_files}${file}\n"
        fi

    done < <(
        git diff \
            --cached \
            --name-only \
            --diff-filter=ACMR
    )

    if [ -n "${suspicious_files}" ]; then
        printf '%b' "${suspicious_files}"
        return 1
    fi

    return 0
}

handle_local_changes() {
    local current_remote
    local suspicious

    if [ "${DRY_RUN}" = "true" ]; then
        bashio::log.info "[DRY RUN] Local changes are ready to be committed and pushed."
        return
    fi

    bashio::log.info "Staging local Home Assistant configuration changes..."

    git add -A

    suspicious="$(scan_staged_secrets)" || {
        git reset >/dev/null

        bashio::log.error "Potential secret detected. Automatic push stopped."
        bashio::log.error "Affected files:"
        printf '%s\n' "${suspicious}"

        notify_issue \
            "HA Config Sync blocked" \
            "Potential secret or runtime token detected in local configuration changes. Automatic Git push was stopped. Check the HA Config Sync App logs."

        return
    }

    bashio::log.info "Running Home Assistant configuration validation..."

    if ! check_config; then
        git reset >/dev/null

        bashio::log.error "Home Assistant configuration check failed."

        notify_issue \
            "HA Config Sync blocked" \
            "Local configuration changes failed the Home Assistant configuration check. Nothing was committed or pushed."

        return
    fi

    #
    # Fetch again immediately before committing.
    # This closes most of the race window where GitHub could have changed
    # while we were validating the local configuration.
    #
    if ! git fetch "${REMOTE}" "${BRANCH}" --quiet; then
        git reset >/dev/null

        notify_issue \
            "HA Config Sync network error" \
            "Could not fetch the remote repository before committing local changes."

        return
    fi

    current_remote="$(git rev-parse "${REMOTE}/${BRANCH}")"

    if [ "$(git rev-parse HEAD)" != "${current_remote}" ]; then
        git reset >/dev/null

        bashio::log.warning "Remote changed while local configuration was being prepared."

        notify_issue \
            "HA Config Sync conflict" \
            "GitHub changed while local Home Assistant changes were waiting to be committed. Automatic synchronization was stopped."

        return
    fi

    if ! git config user.name >/dev/null || ! git config user.email >/dev/null; then
        git reset >/dev/null

        notify_issue \
            "HA Config Sync configuration error" \
            "Git user.name or user.email is not configured for the Home Assistant repository."

        return
    fi

    git commit \
        -m "HA sync: local configuration update $(date '+%Y-%m-%d %H:%M:%S')" \
        >/dev/null

    bashio::log.info "Local configuration committed."

    if git push "${REMOTE}" "HEAD:${BRANCH}"; then
        bashio::log.info "Local configuration pushed successfully."
        dismiss_issue
    else
        bashio::log.warning "Push failed. Local commit was preserved."

        notify_issue \
            "HA Config Sync conflict" \
            "The local configuration was committed, but GitHub rejected the push. The local commit is preserved and no changes were overwritten."
    fi
}

handle_remote_changes() {
    local old_head="$1"
    local remote_head="$2"
    local changed_files

    changed_files="$(git diff --name-only "${old_head}..${remote_head}")"

    if [ "${DRY_RUN}" = "true" ]; then
        bashio::log.info "[DRY RUN] Remote changes can be fast-forwarded safely."
        bashio::log.info "Remote files changed:"
        printf '%s\n' "${changed_files}"
        return
    fi

    bashio::log.info "Applying remote fast-forward update..."

    if ! git merge --ff-only "${remote_head}"; then
        notify_issue \
            "HA Config Sync conflict" \
            "Remote configuration could not be applied using fast-forward only."

        return
    fi

    bashio::log.info "Running Home Assistant configuration validation..."

    if ! check_config; then
        bashio::log.error "Remote configuration failed validation. Rolling back."

        git reset --hard "${old_head}"

        notify_issue \
            "HA Config Sync rollback" \
            "A GitHub configuration update failed Home Assistant validation and was rolled back automatically."
	printf '%s\n' "${remote_head}" > /data/rejected_remote_commit
        
	return
    fi

    if [ "${AUTO_RELOAD}" = "true" ] \
        && printf '%s\n' "${changed_files}" | grep -Eq '\.(yaml|yml)$'
    then
        bashio::log.info "Reloading Home Assistant YAML configuration..."

        if ! reload_config; then
            bashio::log.warning "Configuration was updated, but reload_all failed."

            notify_issue \
                "HA Config Sync reload warning" \
                "GitHub configuration was applied successfully, but Home Assistant reload_all failed. A manual reload or restart may be required."

            return
        fi
    fi

    bashio::log.info "Remote configuration applied successfully."
    rm -f /data/rejected_remote_commit
    dismiss_issue
}

sync_once() {
    local local_head
    local remote_head
    local dirty
    local signature
    local now


    if ! git fetch "${REMOTE}" "${BRANCH}" --quiet; then
        bashio::log.warning "Git fetch failed."

        notify_issue \
            "HA Config Sync network error" \
            "Could not fetch ${REMOTE}/${BRANCH}. Local configuration was not changed."

        return
    fi

    local_head="$(git rev-parse HEAD)"
    remote_head="$(git rev-parse "${REMOTE}/${BRANCH}")"

	#
    # Do not retry a remote commit that already failed HA validation.
    #
    if [ -f /data/rejected_remote_commit ] \
        && [ "$(cat /data/rejected_remote_commit)" = "${remote_head}" ]
    then
        bashio::log.warning \
            "Remote commit ${remote_head} was previously rejected by Home Assistant validation."
        return
    fi
	

    if [ -n "$(git status --porcelain)" ]; then
        dirty=true
    else
        dirty=false
    fi

    #
    # CASE 1:
    # Local working-tree changes while both Git heads are still identical.
    #
    if [ "${dirty}" = "true" ] && [ "${local_head}" = "${remote_head}" ]; then
        signature="$(get_dirty_signature)"
        now="$(date +%s)"

        if [ "${signature}" != "${DIRTY_SIGNATURE}" ]; then
            DIRTY_SIGNATURE="${signature}"
            DIRTY_SINCE="${now}"

            bashio::log.info \
                "Local configuration change detected. Waiting ${LOCAL_SETTLE_SECONDS}s for edits to settle."

            return
        fi

        if [ $((now - DIRTY_SINCE)) -lt "${LOCAL_SETTLE_SECONDS}" ]; then
            return
        fi

        handle_local_changes

        DIRTY_SIGNATURE=""
        DIRTY_SINCE=0
        return
    fi

    DIRTY_SIGNATURE=""
    DIRTY_SINCE=0

    #
    # Any uncommitted local change combined with different Git heads is
    # treated as a conflict. Never merge automatically.
    #
    if [ "${dirty}" = "true" ]; then
        bashio::log.warning \
            "Local working-tree changes and remote/local Git history differences exist."

        notify_issue \
            "HA Config Sync conflict" \
            "Local Home Assistant configuration changes coexist with Git history changes. Automatic synchronization was stopped to prevent overwriting local work."

        return
    fi

    #
    # CASE 2:
    # Fully synchronized.
    #
    if [ "${local_head}" = "${remote_head}" ]; then
        dismiss_issue
        return
    fi

    #
    # CASE 3:
    # Remote is strictly ahead -> safe fast-forward candidate.
    #
    if git merge-base --is-ancestor "${local_head}" "${remote_head}"; then
        handle_remote_changes "${local_head}" "${remote_head}"
        return
    fi

    #
    # CASE 4:
    # Local contains commits not yet present remotely.
    #
    if git merge-base --is-ancestor "${remote_head}" "${local_head}"; then
        if [ "${DRY_RUN}" = "true" ]; then
            bashio::log.info "[DRY RUN] Local branch is ahead and could be pushed."
            return
        fi

        if git push "${REMOTE}" "HEAD:${BRANCH}"; then
            bashio::log.info "Pending local commit pushed successfully."
            dismiss_issue
        else
            notify_issue \
                "HA Config Sync push error" \
                "Local Git commits could not be pushed. They remain safely stored locally."
        fi

        return
    fi

    #
    # CASE 5:
    # Histories diverged.
    #
    bashio::log.warning "Local and remote Git histories have diverged."

    notify_issue \
        "HA Config Sync conflict" \
        "Local and GitHub histories have diverged. No automatic merge, rebase, reset or overwrite was performed."
}

main() {
    bashio::log.info "Starting HA Config Sync"
    bashio::log.info "Repository: ${REPO}"
    bashio::log.info "Remote: ${REMOTE}/${BRANCH}"
    bashio::log.info "Poll interval: ${POLL_INTERVAL}s"
    bashio::log.info "Local settle time: ${LOCAL_SETTLE_SECONDS}s"
    bashio::log.info "Dry run: ${DRY_RUN}"

    if [ ! -d "${REPO}/.git" ]; then
        bashio::log.fatal "/config is not a Git repository."
        exit 1
    fi

    cd "${REPO}"

    git config --global --add safe.directory "${REPO}"

    while true; do
        sync_once || bashio::log.error "Unexpected synchronization error."
        sleep "${POLL_INTERVAL}"
    done
}

main

// Kanban board behaviour for Redmine 7 (no jQuery): native drag and drop,
// modal dialogs, fetch-based updates. The DOM contract (element ids, the
// ./update_status, ./get_journal and ./put_journal endpoints) is unchanged
// from the jQuery original.

function byId(id) {
  return document.getElementById(id);
}

function csrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta ? meta.content : '';
}

function post(url, params) {
  return fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'X-CSRF-Token': csrfToken(),
      'X-Requested-With': 'XMLHttpRequest',
      'Accept': 'application/json'
    },
    body: new URLSearchParams(params).toString()
  }).then(function(response) {
    if (!response.ok) { throw new Error(response.status); }
    return response.json();
  });
}

// Minimal modal: moves bodyEl into a fixed overlay until a button closes it.
function showDialog(title, bodyEl, buttons) {
  const previousParent = bodyEl.parentNode;
  const previousDisplay = bodyEl.style.display;
  const backdrop = document.createElement('div');
  backdrop.className = 'kanban-modal-backdrop';
  const box = document.createElement('div');
  box.className = 'kanban-modal';
  const heading = document.createElement('h3');
  heading.textContent = title;
  box.appendChild(heading);
  bodyEl.style.display = '';
  box.appendChild(bodyEl);
  const buttonRow = document.createElement('div');
  buttonRow.className = 'kanban-modal-buttons';
  buttons.forEach(function(button) {
    const element = document.createElement('button');
    element.type = 'button';
    element.className = button.default ? 'btn btn-primary' : 'btn';
    element.textContent = button.label;
    element.addEventListener('click', function() {
      backdrop.remove();
      bodyEl.style.display = previousDisplay;
      previousParent.appendChild(bodyEl);
      if (button.handler) { button.handler(); }
    });
    buttonRow.appendChild(element);
  });
  box.appendChild(buttonRow);
  backdrop.appendChild(box);
  backdrop.addEventListener('click', function(event) {
    if (event.target === backdrop) {
      backdrop.remove();
      bodyEl.style.display = previousDisplay;
      previousParent.appendChild(bodyEl);
    }
  });
  document.body.appendChild(backdrop);
}

function reloadBoard() {
  byId('form1').submit();
}

//
// Save ticket (change status and assignee, save comment)
//
function saveTicket(card_id, from_field_id, to_field_id, comment) {
  post('./update_status', {
    'card_id': card_id,
    'field_id': to_field_id,
    'comment': comment
  }).then(function(data) {
    if (data.result === 'OK') {
      const tmp1 = to_field_id.split('-');
      const tmp2 = from_field_id.split('-');
      // Count up the destination column header, count down the source
      const toCounter = byId('counter-' + tmp1[1]);
      toCounter.innerHTML = Number(toCounter.innerHTML) + 1;
      const fromCounter = byId('counter-' + tmp2[1]);
      fromCounter.innerHTML = Number(fromCounter.innerHTML) - 1;
      const wip_field = Number(byId('wip-field').innerHTML);
      const wip_limit = byId('wip_max').value;
      let wip_next1 = null;
      let wip_next2 = null;
      // Case card moved to the WIP column (count up)
      if (tmp1[1] == wip_field) {
        if (tmp1[2] == tmp2[2]) { // same user
          wip_next1 = Number(byId('wip-' + tmp1[2]).innerHTML) + 1;
          byId('wip-' + tmp1[2]).innerHTML = wip_next1;
        } else { // different user
          if (tmp1[2] == tmp2[2]) { // same status
            if (data.user_id != null) {
              wip_next1 = Number(byId('wip-' + tmp1[2]).innerHTML) + 1;
              byId('wip-' + tmp1[2]).innerHTML = wip_next1;
            }
            wip_next2 = Number(byId('wip-' + tmp2[2]).innerHTML) - 1;
            byId('wip-' + tmp2[2]).innerHTML = wip_next2;
          } else { // different status
            wip_next1 = Number(byId('wip-' + tmp1[2]).innerHTML) + 1;
            byId('wip-' + tmp1[2]).innerHTML = wip_next1;
          }
        }
        if (wip_next1 > Number(wip_limit)) {
          byId(to_field_id).prepend(byId('wip_error-' + tmp1[2]));
          byId('wip_error-' + tmp1[2]).style.display = '';
        } else {
          byId('wip_error-' + tmp1[2]).style.display = 'none';
        }
      }
      // Case card moved out of the WIP column (count down)
      if (tmp2[1] == wip_field) {
        if (tmp1[2] == tmp2[2]) { // same user
          wip_next2 = Number(byId('wip-' + tmp2[2]).innerHTML) - 1;
          byId('wip-' + tmp2[2]).innerHTML = wip_next2;
        } else { // different user
          if (tmp1[2] == tmp2[2]) { // same status
            if (data.user_id != null) {
              wip_next1 = Number(byId('wip-' + tmp1[2]).innerHTML) + 1;
              byId('wip-' + tmp1[2]).innerHTML = wip_next1;
            }
            wip_next2 = Number(byId('wip-' + tmp2[2]).innerHTML) - 1;
            byId('wip-' + tmp2[2]).innerHTML = wip_next2;
          } else { // different status
            wip_next2 = Number(byId('wip-' + tmp2[2]).innerHTML) - 1;
            byId('wip-' + tmp2[2]).innerHTML = wip_next2;
          }
        }
        if (wip_next2 > Number(wip_limit)) {
          byId(from_field_id).prepend(byId('wip_error-' + tmp2[2]));
          byId('wip_error-' + tmp2[2]).style.display = '';
        } else {
          byId('wip_error-' + tmp2[2]).style.display = 'none';
        }
      }
      // Write the assignee name on the card
      if (data.user_id != null) {
        byId('user_name_' + card_id).innerHTML = byId('user_name_user_id-' + data.user_id).innerHTML;
      } else {
        byId('user_name_' + card_id).innerHTML = '<p>Not assigned</p>';
      }
    }
    if (data.result === 'NG') {
      alert('Operation not permitted');
      reloadBoard();
    }
  }).catch(function() {
    reloadBoard();
  });
}

//
// Get journal (recent notes shown in the sidebar on card hover)
//
function getJournal(card_id) {
  post('./get_journal', { 'card_id': card_id }).then(function(data) {
    if (data.result === 'OK') {
      byId('sidebar').innerHTML = data.notes;
      byId('submit-journal-button').addEventListener('click', function() {
        putJournal(card_id);
      });
    }
  }).catch(function() {
    // Journal is a convenience; leave the sidebar as it was.
  });
}

//
// Add a new journal entry from the sidebar
//
function putJournal(card_id) {
  const note = byId('comment_area').value;
  post('./put_journal', { 'card_id': card_id, 'note': note }).then(function(data) {
    if (data.result === 'OK') {
      getJournal(card_id);
    }
  }).catch(function() {
    // Same as above: nothing to recover into.
  });
}

document.addEventListener('DOMContentLoaded', function() {
  // Show the sidebar and give it room
  byId('main').classList.remove('nosidebar');
  byId('sidebar').style.cssText = 'padding: 0 8px 0 8px !important';

  // Initial message when no note has been loaded yet
  byId('sidebar').innerHTML =
    '<table class="my-journal-table"><tr><td>' + label_recent_history_is_here + '</td></tr></table>';

  // Load the journal after hovering a card for 500 ms
  let hoverTimeout;
  document.querySelectorAll('[id^="issue-"]').forEach(function(card) {
    card.addEventListener('mouseenter', function() {
      hoverTimeout = setTimeout(function() {
        getJournal(card.id);
      }, 500);
    });
    card.addEventListener('mouseleave', function() {
      clearTimeout(hoverTimeout);
    });
  });

  // Keep the scroll position for the next reload
  window.addEventListener('scroll', function() {
    byId('scroll_top').value = window.scrollY;
  });

  // Native drag and drop: cards into columns
  document.querySelectorAll('[id^="issue-"]').forEach(function(card) {
    card.setAttribute('draggable', 'true');
    card.addEventListener('dragstart', function(event) {
      event.dataTransfer.setData('text/plain', card.id);
      event.dataTransfer.effectAllowed = 'move';
      card.classList.add('dragged-issue-card');
    });
    card.addEventListener('dragend', function() {
      card.classList.remove('dragged-issue-card');
    });
  });
  document.querySelectorAll('[id^="field-"]').forEach(function(field) {
    field.addEventListener('dragover', function(event) {
      event.preventDefault();
      event.dataTransfer.dropEffect = 'move';
      field.classList.add('kanban-drop-target');
    });
    field.addEventListener('dragleave', function() {
      field.classList.remove('kanban-drop-target');
    });
    field.addEventListener('drop', function(event) {
      event.preventDefault();
      field.classList.remove('kanban-drop-target');
      const cardId = event.dataTransfer.getData('text/plain');
      const card = byId(cardId);
      if (!card) { return; }
      const fromFieldId = card.parentElement.id;
      byId('save_card_id').value = cardId;
      byId('save_from_field_id').value = fromFieldId;
      byId('save_to_field_id').value = field.id;
      // Drop in the upper half inserts at the top, else at the bottom
      const rect = field.getBoundingClientRect();
      if (event.clientY < rect.top + rect.height / 2) {
        field.prepend(card);
      } else {
        field.appendChild(card);
      }
      if (option_display_comment_dialog_when_drop === '1') {
        showDialog(label_add_notes, byId('comment-dialog'), [
          {
            label: 'OK',
            default: true,
            handler: function() {
              saveTicket(
                byId('save_card_id').value,
                byId('save_from_field_id').value,
                byId('save_to_field_id').value,
                byId('comment-of-dialog').value
              );
              byId('comment-of-dialog').value = '';
            }
          },
          {
            label: 'Cancel',
            handler: reloadBoard
          }
        ]);
      } else {
        saveTicket(cardId, fromFieldId, field.id, '');
      }
    });
  });

  // Only open versions checkbox
  byId('cbx').addEventListener('change', function() {
    byId('open_versions').value = this.checked ? '1' : '0';
  });

  // Show ancestor checkbox
  byId('cb_ancestor').addEventListener('change', function() {
    byId('show_ancestors').value = this.checked ? '1' : '0';
  });
});

// Suppress messages "Leave this site?"
Object.defineProperty(window, 'onbeforeunload', {
  set(newValue) {
    if (typeof newValue === 'function') window.onbeforeunload = null;
  }
});

// Keyboard shortcuts (hotkeys-js, no dependencies)
hotkeys('o,e,k,d+u,d+o,d+t,d+w,n,s,h,l,p', function(event, handler) {
  switch (handler.key) {
    // assignee == (login user)
    case 'o':
      byId('user_id').value = login_user_id;
      break;
    // assignee == (everyone in the project)
    case 'e':
      byId('user_id').value = 'unspecified';
      break;
    // due_date == unspecified
    case 'd+u':
      byId('due_date').value = 'unspecified';
      break;
    // due_date == overdue
    case 'd+o':
      byId('due_date').value = 'overdue';
      break;
    // due_date == today
    case 'd+t':
      byId('due_date').value = 'today';
      break;
    // due_date == this week
    case 'd+w':
      byId('due_date').value = 'thisweek';
      break;
    // card_size == normal_days_left
    case 'n':
      byId('card_size').value = 'normal_days_left';
      break;
    // card_size == normal_estimated_hours
    case 'k':
      byId('card_size').value = 'normal_estimated_hours';
      break;
    // card_size == normal_spent_hours
    case 'p':
      byId('card_size').value = 'normal_spent_hours';
      break;
    // card_size == small
    case 's':
      byId('card_size').value = 'small';
      break;
    // show this
    case 'h':
      showDialog('Keyboard Shortcuts', byId('keyboard-chortcut-dialog'), [
        { label: 'OK', default: true }
      ]);
      return;
    // select all open issues
    case 'l':
      byId('open-field-ids').innerHTML.trim().split(/\s+/).filter(Boolean).forEach(function(statusId) {
        document.querySelectorAll('[id^="field-' + statusId + '-"]').forEach(function(field) {
          field.querySelectorAll('input').forEach(function(input) {
            input.click();
          });
        });
      });
      return;
  }
  // reload page
  reloadBoard();
});

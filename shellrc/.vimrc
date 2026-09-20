" ~/.vimrc — clipboard for classic vim on Wayland.
"
" THE PROBLEM THIS FILE SOLVES
" Arch's vim 9.2 package is built WITHOUT any clipboard backend:
"
"   vim --version  ->  -clipboard  -wayland_clipboard  -xterm_clipboard
"
" 'clipmethod' defaults to "wayland,x11" and vim tries both, finds neither
" compiled in, and ends at  v:clipmethod = none.  With no method there is no
" "+" register at all (has('unnamedplus') returns 0), so yanking never reaches
" the desktop clipboard and there is nothing to paste from.  That is not a
" misconfiguration, it is what that build can do on its own.
"
" THE FIX, AND WHY THIS ONE
" vim 9.2 added +clipboard_provider (:help clipboard-providers): the "+" and
" "*" registers can be handed to script functions, and a provider works even
" in a build with -clipboard.  So the registers are wired to wl-copy and
" wl-paste, which are already installed and are what every other Wayland app
" on this machine uses.
"
" The alternative was installing the `gvim` package for a +clipboard build and
" letting it reach the clipboard through XWayland.  Rejected: it pulls in GTK
" and X11 to bounce the selection through a compatibility layer, when the
" native tools are already here and the provider API exists for exactly this.

if executable('wl-copy') && executable('wl-paste')

  " Only claim to work when there is actually a Wayland session to talk to.
  " Vim skips a provider whose available() is false and falls through to the
  " next 'clipmethod' entry, so this stays correct in a TTY or over ssh.
  func! s:WlAvailable() abort
    return !empty($WAYLAND_DISPLAY)
  endfunc

  " "*" is the PRIMARY selection (select with the mouse, paste with middle
  " click) and "+" is the ordinary clipboard (ctrl+c / ctrl+v elsewhere).
  " Same split every Wayland app uses, so vim behaves like the rest of them.
  func! s:WlFlags(reg) abort
    return a:reg ==# '*' ? ' --primary' : ''
  endfunc

  " The newline rules here were measured, and the first version of this file
  " had them backwards, so they are written down:
  "
  "   wl-copy  stores stdin VERBATIM.  -n/--trim-newline strips one trailing
  "            newline from it, and adds nothing.
  "   wl-paste APPENDS one newline to its output for text types, which is why
  "            --no-newline exists.  It is the reader adding that newline,
  "            not the writer.
  "
  " Verified by copying "this" and "this\n" with and without -n and reading
  " the byte counts back (5/6/5/5), plus an application/octet-stream round
  " trip, which comes back as exactly one byte because the newline rule is a
  " text-type rule on the PASTE side.
  "
  " So: a charwise yank goes out with -n, because the clipboard must hold the
  " word and nothing else — paste a word carrying a newline into a browser
  " field and it submits the form. A linewise yank sends its own trailing
  " newline, because a line copied out of vim should arrive in the next app
  " as a line.
  func! s:WlCopy(reg, type, lines) abort
    let l:text = join(a:lines, "\n")
    if a:type ==# 'V'
      call system('wl-copy' . s:WlFlags(a:reg) . ' --type text/plain', l:text . "\n")
    else
      call system('wl-copy --trim-newline' . s:WlFlags(a:reg) . ' --type text/plain', l:text)
    endif
  endfunc

  " Coming back the other way, the question is whether to hand vim LINEWISE
  " text (p puts it on its own line) or CHARWISE (p drops it where the cursor
  " is). Getting it wrong is the difference between pasting a word into the
  " middle of a sentence and pasting it onto a line of its own.
  "
  " The first newline off wl-paste's output is ITS OWN, per the note above, so
  " it is removed before anything is decided — otherwise every one-word
  " clipboard looks like it ends in a newline and comes back linewise, which
  " is exactly what the first version of this did.
  "
  " What is left is the real clipboard, and it is linewise only when it holds
  " whole lines: more than one of them, with a trailing newline closing the
  " last. Anything else is charwise, including a multi-line fragment that
  " stops mid-line.
  func! s:WlPaste(reg) abort
    let l:raw = system('wl-paste' . s:WlFlags(a:reg))
    if v:shell_error
      return ['', []]
    endif
    let l:content = substitute(l:raw, "\n$", '', '')
    let l:lines = split(l:content, "\n", 1)
    let l:ends_nl = 0
    if len(l:lines) > 1 && l:lines[-1] ==# ''
      call remove(l:lines, -1)
      let l:ends_nl = 1
    endif
    return [(len(l:lines) > 1 && l:ends_nl) ? 'V' : 'v', l:lines]
  endfunc

  let v:clipproviders['wlclipboard'] = {
        \ 'available': function('s:WlAvailable'),
        \ 'copy':  { '+': function('s:WlCopy'),  '*': function('s:WlCopy') },
        \ 'paste': { '+': function('s:WlPaste'), '*': function('s:WlPaste') },
        \ }

  " ^= puts it FIRST, ahead of the built-in wayland/x11 entries that this
  " build cannot use anyway.
  set clipmethod^=wlclipboard

  " And make the plain commands use it, so y and p are the desktop clipboard
  " without having to type "+y and "+p every time. The cost, worth knowing:
  " d and x also overwrite the clipboard, because in vim deleting IS cutting.
  set clipboard=unnamedplus
endif

" ── Everything below is comfort, not clipboard ────────────────────────────
" Arch's vim already sources /usr/share/vim/vim92/defaults.vim, which turns on
" syntax highlighting, incremental search and a sensible backspace. These are
" the few things that file leaves off and a new user notices immediately.
set number                 " line numbers
set mouse=a                " select, scroll and place the cursor with the mouse
set ignorecase smartcase   " searching /word matches Word, /Word matches only Word
set expandtab tabstop=4 shiftwidth=4 softtabstop=4
set scrolloff=4            " keep four lines visible above and below the cursor
set clipboard+=unnamed     " the "* register too, so middle-click paste works

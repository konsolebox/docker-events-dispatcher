# docker-events-dispatcher

This gem provides an executable script that listens for events from
dockerd and executes executable files in
`/etc/docker-events-dispatcher.d`.

Files are executed with the event type as the first argument,
the action as the second argument, and the whole event data in JSON
format as the third.

Files not having executable bit are ignored.

Script respects the file's owner and forks and changes UID and GID
accordingly before executing the file.

The script can only work by running it as root.

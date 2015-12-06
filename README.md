# ktermpool

##Description
KTermPool is an [AwesomeWM 3.5](https://github.com/awesomeWM/awesome) module that will keep a
stack of hidden (but started) clients, and will show one of them when it notices AwesomeWM
spawning a command that would create one.

This reduces the time between issuing the spawn command and having the client ready, which is
pretty useful when having a lot of terminals with expensive loads or just a slow computer.

When KTermPool is provided with a command, it will spawn several hidden clients and then it
will intercept calls to `awful.util.spawn` to show one of the hidden clients, after which the
pool is filled again.
    
The intent of this module is to be used with terminal spawning commands, but there's no problem
when using it with other kind of window-creating commands, just be aware of:
* When Awesome exits, remaining clients in the pool will be KILLED
* The command stars executing even when its client is not shown
* If the command exits before a client is shown, it will consume a
  slot in the pool and this slot wont be freed until its pid gets
  reused by the system (in fact, this will cause the client to be
  hidden, since KTermPool will misinterpret it as a command to be
  handled).
  This shouldn't be a problem with terminal or other GUI commands
  but if you are worried about it, you may want to enable the
  pool garbage collector, which fixes this problem with only a
  periodic task.
    
##Usage
Just copy ktermpool.lua in your */awesome folder and load it in your rc.lua like this:  
`require("ktermpool").addCmd(terminal, 5)`  
the API is simple:  
  
* `addCmd( cmd [, poolSize = 1 ])`  
Registers a command to be intercepted and handled, it will spawn poolSize hidden commands.  
  
* `removeCmd( cmd )`  
Unregisters a command, killing all hidden clients.  
  
* `enableGC()`  
Enables garbage collection, it will check periodically if the pids that are marked as "spawned" are actually spawned, and remove them otherwise.

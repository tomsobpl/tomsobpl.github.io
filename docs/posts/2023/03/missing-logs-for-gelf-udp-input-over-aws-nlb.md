---
date:
    created: 2025-03-06
tags:
- aws
- nlb
- graylog
- gelf
- udp 
---

# Missing logs for GELF UDP input over AWS NLB

![header](/assets/blog/missing-logs-for-gelf-udp-input-over-aws-nlb/header.webp){alt="Engineer wondering why not all logs are visible in the system."}

!!! question "Does your cluster really log everything?"

    Are you using a Graylog cluster with a GELF UDP input behind a load balancer in your monitoring stack? If so, you're probably irretrievably losing logs (especially the longer ones) and don't even know it!

## How it all started?

Recently, my team encountered an issue with missing data being written to Graylog SIEM, which was visible in the application logs.

Initially, it seemed that the missing data was occurring at random intervals unrelated to higher load. We also did not notice any network issues.

Upon further analysis, it turned out that the missing data was most likely from the higher payload and it may be related to the MTU value.

<!-- more -->

## How to reproduce the problem?

The applications whose data was missing used the [pygelf](https://pypi.org/project/pygelf/){target="_blank"} library for logging as one of the ones recommended by the Graylog community, so reproducing the problem seemed relatively easy.

``` py linenums="1" title="gelf_logging_test.py"
import logging

from pygelf import GelfUdpHandler

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger()
logger.addHandler(GelfUdpHandler(host="127.0.0.1", port=9402))

for x in [5, 50, 500, 5000, 50000]:
	logger.info(f"Logging payload with {x} characters")
	logger.info("a" * x)
```

### "Weird, it works for me." What's next?

It was not possible to reproduce the error, so another analysis was needed. This time of the library itself and what is happening in it. At first, two parameters specific to the UDP handler stand out.

`chunk_size (1300 by default)`
: maximum length of the message. If log length exceeds this value, it splits into multiple chunks (see [https://www.graylog.org/resources/gelf/](https://www.graylog.org/resources/gelf/){target="_blank"} section “chunked GELF”) with the length equals to this value. This parameter must be less than the MTU. If the logs don’t seem to be delivered, try to reduce this value.

`compress (True by default)`
: if true, compress log messages before sending them to the server

Due to the fact that compression of even a gigantic string consisting of just one character is probably extremely effective, it was initially disabled in the handler.

``` py linenums="7" title="gelf_logging_test.py"
logger.addHandler(GelfUdpHandler(host="127.0.0.1", port=9402, compress=False))
```

Disabling compression also did not cause any errors, so we started testing logs with different `chunk_size` settings. 

The source code contains a comment that the number of chunks cannot be greater than 128.

``` py linenums="66" title="pygelf/handlers.py"
class GelfUdpHandler(BaseHandler, DatagramHandler):

    def __init__(self, host, port, compress=True, chunk_size=1300, **kwargs):
        """
        Logging handler that transforms each record into GELF (graylog extended log format) and sends it over UDP.
        If message length exceeds chunk_size, the message splits into multiple chunks.
        The number of chunks must be less than 128.

```

Even though the logs sent by our applications are not large enough to exceed this limit, we decided to perform tests with different settings of this value.

``` py linenums="1" title="gelf_logging_with_variable_chunk_size_test.py"
import logging

from pygelf import GelfUdpHandler

logging.basicConfig(level=logging.INFO)

for s in [100, 300, 1000, 1500, 2500, 5000, 9000]:
    logger = logging.getLogger()
    logger.addHandler(GelfUdpHandler(host="127.0.0.1", port=9402, compress=False, chunk_size=s))
    logger.info(f"Logging handler with chunk_size set to {s}")

    for x in [5, 50, 500, 5000, 50000]:
        logger.info(f"Logging payload with {x} characters")
        logger.info("a" * x)
```

This test confirmed that indeed the largest message was skipped by the server for the smallest `chunk_size` values ​​of `100` or `300`.

!!! note "Why?"

    50 thousand characters divided into pieces of 300 gives us 167 chunks to send, thus exceeding the 128-chunk limit accepted by the server.

Unfortunately, this still does not solve our problem because the logs not actually saved by the server did not exceed this amount.

### That's not enough. We have to go deeper!

Looking through the sources we can find the [GelfChunkAggregator](https://github.com/Graylog2/graylog2-server/blob/master/graylog2-server/src/main/java/org/graylog2/inputs/codecs/GelfChunkAggregator.java){target="_blank"} class responsible for aggregating UDP packets into the original message, which confirms the information contained in the library regarding the maximum number of 128 chunks.

``` java linenums="51" title="GelfChunkAggregator.java"
public class GelfChunkAggregator implements CodecAggregator {
    private static final Logger log = LoggerFactory.getLogger(GelfChunkAggregator.class);

    private static final int MAX_CHUNKS = 128;
    public static final Result VALID_EMPTY_RESULT = new Result(null, true);
    public static final Result INVALID_RESULT = new Result(null, false);
    public static final int VALIDITY_PERIOD = 5000; // millis
    private static final long CHECK_PERIOD = 1000;

    public static final String CHUNK_COUNTER = name(GelfChunkAggregator.class, "total-chunks");
    public static final String WAITING_MESSAGES = name(GelfChunkAggregator.class, "waiting-messages");
    public static final String COMPLETE_MESSAGES = name(GelfChunkAggregator.class, "complete-messages");
    public static final String EXPIRED_MESSAGES = name(GelfChunkAggregator.class, "expired-messages");
    public static final String EXPIRED_CHUNKS = name(GelfChunkAggregator.class, "expired-chunks");
    public static final String DUPLICATE_CHUNKS = name(GelfChunkAggregator.class, "duplicate-chunks");
```

In addition, in line 57 we can find a value defining the time in which all chunks of the message must reach the server. This is confirmed by subsequent fragments of the code of this class.

``` java linenums="186" title="GelfChunkAggregator.java"
// message isn't complete yet, check if we should remove the other parts as well
if (isOutdated(entry)) {
    // chunks are outdated, the oldest came in over 5 seconds ago, clean them all up
    log.debug("Not all chunks of <{}> arrived within {}ms. Dropping chunks.", messageId, VALIDITY_PERIOD);
    expireEntry(messageId);
}
```

``` java linenums="202" title="GelfChunkAggregator.java"
private boolean isOutdated(ChunkEntry entry) {
    return (Tools.nowUTC().getMillis() - entry.firstTimestamp) > VALIDITY_PERIOD;
}
```

After this analysis, we were certain of three things:

1. The message cannot be split into more than 128 chunks (we have less because we counted)
2. All chunks must be delivered in less than 5 seconds (we deliver in less because we checked)
3. We must deliver all parts so that the message can be aggregated (obvious)

### Don't assume something is obvious, just check!

Since it was clear that we don't split the message into more than 128 chunks and send them all in less than 5 seconds, I decided to check if the problem isn't somewhere on the network side and some packets aren't reaching their destination (remember, we're working with a UDP connection).

![header](/assets/blog/missing-logs-for-gelf-udp-input-over-aws-nlb/network_flow.png){alt="Log records flow between application and Graylog cluster."}

First, I wanted to check how the load balancer record is resolved in the application and whether the problem does not occur when we try to send information between different Availability Zones.

I decided to look at the sources of the `pygelf` library and check whether it is prepared to log where it sends data in the case of configured logging at the `DEBUG` level.

``` python linenums="85" title="pygelf/pygelf/handlers.py"
def send(self, s):
    if len(s) <= self.chunk_size:
        DatagramHandler.send(self, s)
        return

    chunks = gelf.split(s, self.chunk_size)
    for chunk in chunks:
        DatagramHandler.send(self, chunk)
```

Since the `GelfUdpHandler` class does not have such options and simply calls the `send` method on the `DatagramHandler` object, I decided to go deeper and started browsing the Python sources.

What caught my attention was the fact that the mentioned `DatagramHandler` during each data write to the socket passes the destination address along with the data, which in our case is in the form of a domain address and not an IP address. In such a situation, the domain address will be converted to an IP address separately for each chunk of the original message. This behavior, in turn, may cause that in some cases chunks of the same message may reach different nodes of the cluster and cause errors.

``` python linenums="737" title="cpython/Lib/logging/handlers.py"
def send(self, s):
    """
    Send a pickled string to a socket.

    This function no longer allows for partial sends which can happen
    when the network is busy - UDP does not guarantee delivery and
    can deliver packets out of sequence.
    """
    if self.sock is None:
        self.createSocket()
    self.sock.sendto(s, self.address)
```

Which is confirmed on the Graylog community forum [here](https://community.graylog.org/t/udp-load-balancer-for-graylog-gelf-udp/6728/2){target="_blank"}

!!! quote "derPhlipsi Philipp Ruland"

    Additionally, it should be obvious that the chunks must arrive at the same server for them to get reassembled, else the message will be discarded instantly. So using round robin or similar load balancing will not work.

Knowing how the mechanism for sending individual packets works, I decided to write a simple lambda function that would simply query DNS many times and return statistics of these queries.

``` python linenums="1" title="dns_check.py"
import json
import os
import socket

def lambda_handler(event, context):
    ips = {}

    for _ in range(0, 5000):
        addr = socket.gethostbyname(os.environ['NLB_PATH'])
        ips.update({addr: ips.get(addr, 0) + 1})

    return {
        'statusCode': 200,
        'body': json.dumps(ips)
    }
```

Another surprise (and if you think about it, it should be obvious) was the fact that Amazon's internal cloud DNS servers do not cache results and each subsequent query returns a different IP address. When querying the DNS server several thousand times in a row, the results are distributed perfectly between all currently available IP addresses.

``` json linenums="1" title="dns_check_output.json"
{
  "statusCode": 200,
  "body": "{\"10.0.1.1\": 1668, \"10.0.2.1\": 1666, \"10.0.3.1\": 1666}"
}
```

### Wait. Why doesn't sticky sessions work?

The answer to this question is very simple. It does work, but we haven't used it. Why? According to [AWS documentation](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/introduction.html){target="_blank"} UDP packets are routed to the same destination based on the protocol type and the source and destination values.

!!! quote "UDP session stickiness"
    For UDP traffic, the load balancer selects a target using a flow hash algorithm based on the protocol, source IP address, source port, destination IP address, and destination port. A UDP flow has the same source and destination, so it is consistently routed to a single target throughout its lifetime. Different UDP flows have different source IP addresses and ports, so they can be routed to different targets.

In our case, when sending each chunk of the message, the library asked the DNS server for the IP address of the load balancer, and according to the assumptions, it sent a different address each time to evenly distribute the traffic.

The load balancer, receiving packets from the same source but sent to a different destination, did not qualify them as a single session and directed the traffic to a different node each time. After sending all the message chunks, they were in the buffers of different nodes and none of them was able to aggregate them into the original message.

After 5 seconds, all chunks of the message were abandoned as incomplete and the log record was irretrievably lost.

## How to fix it?

There is no single solution to this problem, but we decided to perform several smaller operations that will work for a short time before the target solution is implemented.

### Changes in load balancer (instant change)

We decided to use the `Availability Zone DNS affinity` option, which causes the preferred resolved address for the DNS client to be the one in its Availability Zone. This way, each chunk of the message will be sent to the same node. Unfortunately, we will lose the ability to evenly distribute traffic because all lambdas launched in a given zone will always use the node in the same zone they are in. The benefit is immediate recovery for all applications without any changes to the code.

### Changes to the application initialization code (short term workaround)

The next step was to implement a fix by the development teams to the lambda function initialization code to resolve the load balancer address before configuration and restore the load balancer settings to the default configuration. In this way, we improved the reliability of the load balancer itself and improved traffic distribution between cluster nodes. The IP address was not dependent on the zone in which the application was started and was static only for the lifetime of a single lambda function.

### Library improvement and logging flow changes (long term solution)

The final step will be to improve the library so that address resolution does not occur at the level of a part but the whole message and perhaps change the approach to logging. In this way we will return to the initial configuration where we do not have to remember to properly prepare the configuration for the library and maintain a separate version for correct operation.

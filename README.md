一、cker.sh 更换debian 12&13内核

 wget -qO- https://raw.githubusercontent.com/teijiang/sh/main/cker.sh | bash 
--------------------------------------------------------------------------------------------------
二、fix-debian12&13_cve-2026-99999.sh 更换debian 12&13内核修复漏洞

 wget -qO- https://raw.githubusercontent.com/teijiang/sh/main/fix-debian12-13_cve-2026-99999.sh | bash 
--------------------------------------------------------------------------------------------------
三、hy2tj.sh hy2最新支持一键脚本 输出二维码

 wget -qO- https://raw.githubusercontent.com/teijiang/sh/main/hy2tj.sh | bash 
 --------------------------------------------------------------------------------------------------
四、benchx.sh 快速测试GB5评分

 wget -qO- https://raw.githubusercontent.com/teijiang/sh/main/benchx.sh | bash benchx.sh
 --------------------------------------------------------------------------------------------------
五、fio.sh 硬盘经典测试

 wget -qO- https://raw.githubusercontent.com/teijiang/sh/main/fio.sh | bash fio.sh
--------------------------------------------------------------------------------------------------
Block Size | 4k            (IOPS) | 64k           (IOPS)
  ------   | ---            ----  | ----           ---- 
Read       | 501M MB/s (128k)     | 4.61 GB/s (75.6k)   
Write      | 501M MB/s (128k)     | 4.60 GB/s (75.5k)   
Total      | 1002 MB/s (256.0k)   | 9.21 GB/s (151.1k)  
           |                      |                     
Block Size | 512k          (IOPS) | 1m            (IOPS)
  ------   | ---            ----  | ----           ---- 
Read       | 5.01 GB/s (10.3k)    | 4.40 GB/s (4.5k)    
Write      | 5.00 GB/s (10.3k)    | 4.38 GB/s (4.4k)    
Total      | 10.01 GB/s (20.6k)   | 8.78 GB/s (8.9k)   

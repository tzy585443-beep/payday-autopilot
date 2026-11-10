from PIL import Image, ImageDraw, ImageFont
import glob
W,H=1280,720
def font(sz, bold=False):
    c=[f for f in glob.glob('/usr/share/fonts/**/*.ttf',recursive=True) if ('Inter' in f or 'DejaVuSans' in f or 'Roboto' in f) and 'Italic' not in f]
    c.sort(key=lambda f:(('Bold' in f)!=bold, len(f)))
    return ImageFont.truetype(c[0], sz)
def mono(sz):
    c=[f for f in glob.glob('/usr/share/fonts/**/*Mono*.ttf',recursive=True) if 'Italic' not in f]
    return ImageFont.truetype(sorted(c,key=len)[0], sz)
def card(name, title, lines, sub=None, monolines=False, msz=22):
    im=Image.new('RGB',(W,H),(14,17,28)); d=ImageDraw.Draw(im)
    d.rectangle([0,0,W,8],fill=(0,200,170))
    d.text((70,60),title,font=font(52,True),fill=(255,255,255))
    if sub: d.text((70,130),sub,font=font(26),fill=(0,200,170))
    y=200; f=mono(msz) if monolines else font(28)
    for l in lines:
        d.text((70,y),l,font=f,fill=(215,220,235)); y+= 34 if monolines else 46
    d.text((70,H-50),"Reactive Omni Buildathon · Set It and Forget It · MIT",font=font(20),fill=(120,130,150))
    im.save(name)
card('c1.png','Payday Autopilot',[
 'Pay yourself first, automatically.',
 '',
 'When a paycheck lands in your wallet, a reactive contract on',
 'Reactive Network moves your chosen % into savings, on-chain.',
 'It can also pay recurring bills (rent, allowance, DCA) on a schedule.',
 '',
 'No bots. No servers. No keepers. Set the rules once and leave it.'], sub='A personal "set it and forget it" automation on Reactive Omni')
card('c2.png','How it works',[
 'Eth Sepolia (origin)       Reactive Lasna                 Eth Sepolia (dest)',
 '',
 'Employer --transfer--> Transfer(to=wallet)',
 '                         | subscription (topic2 = wallet)',
 '                         v',
 '                  PaydayReactive.react()',
 '                   - trusted payer? >= min income?',
 '                   - requestCallbackV_1_0  ------> proxy -> PaydayExecutor',
 '  Reactive CRON ---> recurring due? (timestamps)        - auth: proxy + sender',
 '                   - requestCallbackV_1_0  ------>      - replay key, 24h cap',
 '                                                        - transferFrom -> savings/payee',
 '',
 'Safety: allowance-only, owner-set destinations, daily cap, pause, never-revert'], sub='event -> reactive -> callback', monolines=True)
card('c3.png','Part 1: tests',['15 Foundry tests including a fuzz test: full loop, income filters,','daily cap, replay protection, CRON schedule, callback auth, pause/resume.'])
card('c4.png','Part 2: LIVE on testnet',[
 'Ethereum Sepolia -> Reactive Lasna -> Ethereum Sepolia',
 '',
 'PaydayReactive (Lasna)   0xC0ad86d5e599E1FBaF249F9aE44e727e4E37b172',
 'PaydayExecutor (Sepolia) 0x89Be54A933d3b9e5c6E45365d859f33df5011EdF',
 'TestUSD (Sepolia)        0xC538D3954531F4AA695f27C2981117f146468102',
 '',
 'Run 1: 3,000 tUSD paycheck -> 20% saved',
 'Run 2: 6,000 tUSD paycheck -> daily cap limits the sweep',
 'Run 3: untrusted sender -> filtered out, nothing moves'], monolines=True)
card('c5.png','Live results',[
 'Paycheck 3,000  origin 0x52b626c7.. -> Lasna 0xc10a71d4.. -> Sepolia 0x79aa8854..  Saved 600',
 'Paycheck 6,000  origin 0xfaeaf5bd.. -> Lasna 0x91b09676.. -> Sepolia 0xeaee6420..  Saved 400 (cap)',
 'Rent via CRON   Lasna 0x3f6e8970..  -> Sepolia 0xcd1047ad..                     RecurringPaid 50',
 'Untrusted 500   origin 0xc7469ec8.. -> Lasna 0xc640e78c..  (no callback)         IncomeIgnored',
 '',
 'Measured: origin -> reactive 12.4 s, origin -> callback 23.6-34.8 s',
 '(includes Sepolia inclusion, ~12 s blocks)',
 '',
 'forge test  |  ./scripts/deploy.sh && ./scripts/demo.sh  |  rules in config.env',
 'Full tx list: README + deployments/testnet.json'], sub='All on-chain, contracts verified on Sourcify', monolines=True, msz=17)

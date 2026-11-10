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
def card(name, title, lines, sub=None, monolines=False):
    im=Image.new('RGB',(W,H),(14,17,28)); d=ImageDraw.Draw(im)
    d.rectangle([0,0,W,8],fill=(0,200,170))
    d.text((70,60),title,font=font(52,True),fill=(255,255,255))
    if sub: d.text((70,130),sub,font=font(26),fill=(0,200,170))
    y=200; f=mono(22) if monolines else font(28)
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
 'Base Sepolia (origin)      Reactive Lasna                 Base Sepolia (dest)',
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
card('c4.png','Part 2: full loop (LOCAL SIMULATION)',[
 'Local anvil node with a mock system contract at 0x8888...8888.',
 'The script plays the network: it delivers the matching log to react()',
 'and posts the requested callback.',
 '',
 'The live testnet run (Lasna + Base Sepolia) uses scripts/demo.sh.',
 'Contract addresses and tx hashes are listed in the README.'])
card('c5.png','Try it',[
 'forge test',
 './scripts/local-sim.sh',
 './scripts/deploy.sh && ./scripts/demo.sh      # Lasna + Base Sepolia',
 '',
 'Rules live in config.env: % saved, minimum income, trusted payers,',
 'daily cap, recurring amount and interval. Change them any time as owner.'], sub='Payday Autopilot: pay yourself first, automatically')

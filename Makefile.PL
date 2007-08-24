use 5.008006;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'WWW::Metaweb',
    VERSION_FROM      => 'lib/WWW/Metaweb.pm', # finds $VERSION
    PREREQ_PM         => {
	Test::Simple => 0.40, # For testing of course.
	JSON => 1.14,
	LWP::UserAgent => 2.033,
	URI::Escape => 3.2
    }, 
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/WWW/Metaweb.pm', # retrieve abstract from module
       AUTHOR         => 'Hayden Stainsby <hds@cpan.org>') : ()),
);
